package espresso

import std.net
import std.poll
import std.thread

// Every option a worker needs after binding, flattened into Send scalars —
// `ServerOptions` is a local class and never crosses a thread.
struct WorkerLimits {
    backlog: int
    max_connections: int
    max_events: int
    poll_timeout_ms: int
    idle_timeout_ms: int
    graceful_shutdown_ms: int
    read_buffer_bytes: int
    max_body_bytes: int
    max_response_body_bytes: int
    max_pending_output_bytes: int
    max_requests_per_connection: int
    max_header_count: int
    max_header_bytes: int
    max_target_bytes: int
    max_head_span_bytes: int

    fn to_options(host: string, port: int) -> ServerOptions {
        var built: ServerOptions = new ServerOptions()
        built.host = host
        built.port = port
        built.backlog = self.backlog
        built.max_connections = self.max_connections
        built.max_events = self.max_events
        built.poll_timeout_ms = self.poll_timeout_ms
        built.idle_timeout_ms = self.idle_timeout_ms
        built.graceful_shutdown_ms = self.graceful_shutdown_ms
        built.read_buffer_bytes = self.read_buffer_bytes
        built.max_body_bytes = self.max_body_bytes
        built.max_response_body_bytes = self.max_response_body_bytes
        built.max_pending_output_bytes = self.max_pending_output_bytes
        built.max_requests_per_connection = self.max_requests_per_connection
        built.max_header_count = self.max_header_count
        built.max_header_bytes = self.max_header_bytes
        built.max_target_bytes = self.max_target_bytes
        built.max_head_span_bytes = self.max_head_span_bytes
        return built
    }
}

fn worker_limits(options: ServerOptions) -> WorkerLimits {
    return WorkerLimits {
        backlog: options.backlog,
        max_connections: options.max_connections,
        max_events: options.max_events,
        poll_timeout_ms: options.poll_timeout_ms,
        idle_timeout_ms: options.idle_timeout_ms,
        graceful_shutdown_ms: options.graceful_shutdown_ms,
        read_buffer_bytes: options.read_buffer_bytes,
        max_body_bytes: options.max_body_bytes,
        max_response_body_bytes: options.max_response_body_bytes,
        max_pending_output_bytes: options.max_pending_output_bytes,
        max_requests_per_connection: options.max_requests_per_connection,
        max_header_count: options.max_header_count,
        max_header_bytes: options.max_header_bytes,
        max_target_bytes: options.max_target_bytes,
        max_head_span_bytes: options.max_head_span_bytes,
    }
}

// One serving worker. It owns an event loop bound to a throwaway port and
// receives its real connections from the acceptor through `intake`; the
// acceptor learns the worker's stop-and-wake handle from `controls`.
// Spawning lives in its own function so the closure moves function
// parameters, which the checker allows where loop-locals are refused.
// A control whose negative signal tells the acceptor this worker never
// started; the acceptor then refuses the whole serve run.
fn failed_control() -> ServerControl {
    return ServerControl {
        stopping: new Atomic<bool>(true),
        signal: -1,
    }
}

fn spawn_worker(
        limits: WorkerLimits,
        intake: IntakeQueue,
        controls: Channel<ServerControl>,
        move factory: send fn() -> Result<WebApplication>) -> Thread<Result<bool>> {
    return thread.spawn(fn() move(factory) -> Result<bool> {
        match factory() {
            ok(app) => {
                match WebServer.bind(
                        app, limits.to_options("127.0.0.1", 0)) {
                    ok(server) => {
                        server.set_intake(intake)
                        controls.send(server.control())
                        server.run()?
                        return ok(true)
                    }
                    err(problem) => {
                        controls.send(failed_control())
                        return err(problem.msg, problem.kind)
                    }
                }
            }
            err(problem) => {
                controls.send(failed_control())
                return err(problem.msg, problem.kind)
            }
        }
    })
}

/// The worker count `serve` should be given when the caller has no stronger
/// opinion. One: measured on macOS (arm64, 8-core), a single loop matches a
/// four-process Bun lane's throughput at lower CPU per request, while extra
/// workers mostly buy kernel-side contention — the platform serializes accepts
/// through one listener regardless. Give more workers only to CPU-heavy
/// handlers that saturate the one loop, and route blocking work through
/// `WorkerPool` either way. Linux gets its own measured default once the
/// Linux lane lands.
pub fn recommended_workers() -> int {
    return 1
}

/// Runs one acceptor plus one serving event loop per factory, all answering
/// on a single port. The calling thread owns the listening socket and deals
/// each connection to the workers round-robin; every worker owns an
/// independent application, service graph, and poller, so requests never
/// contend on shared state. One factory serves from the calling thread
/// alone. Blocks until the workers return.
pub fn serve(
        options: ServerOptions,
        move factories: List<send fn() -> Result<WebApplication>>) -> Result<bool> {
    options.validate()?
    if factories.len() == 0 {
        return err("serve needs at least one worker factory", "config")
    }

    if factories.len() == 1 {
        let only: send fn() -> Result<WebApplication> =
            factories.pop().expect("worker factory")
        let app: WebApplication = only()?
        let server: WebServer = WebServer.bind(app, options)?
        server.run()?
        return ok(true)
    }

    let worker_count: int = factories.len()
    let limits: WorkerLimits = worker_limits(options)
    let handshake: Channel<ServerControl> = new Channel(worker_count)

    var intakes: List<IntakeQueue> = []
    var workers: List<Thread<Result<bool>>> = []
    for index: int in 0..worker_count {
        let intake: IntakeQueue = IntakeQueue {
            streams: new Mutex([]),
            flagged: new Atomic<bool>(false),
        }
        intakes.push(intake)
        let factory: send fn() -> Result<WebApplication> =
            factories.pop().expect("worker factory")
        workers.push(spawn_worker(
            limits, intakes[index], handshake, move factory))
    }

    var controls: List<ServerControl> = []
    var startup_broken: bool = false
    for index: int in 0..worker_count {
        match handshake.receive() {
            some(control) => {
                if control.signal < 0 { startup_broken = true }
                controls.push(control)
            }
            none => { startup_broken = true }
        }
    }

    var failed: Option<Error> = none
    if !startup_broken {
        // The acceptor. Ownership of every connection passes through this
        // loop exactly once: accept, push under the worker's lock, wake it.
        match net.TcpListener.bind_with_backlog(
                options.host, options.port, options.backlog) {
            ok(listener) => {
                var carrier: List<net.TcpStream> = []
                var turn: int = 0
                for {
                    let accepted: Result<net.TcpStream> = listener.accept()
                    var accept_broke: bool = false
                    match accepted {
                        ok(_) => {}
                        err(problem) => {
                            failed = some(problem)
                            accept_broke = true
                        }
                    }
                    if accept_broke { break }
                    carrier.push((move accepted).expect("accepted stream"))
                    intakes[turn].streams.with_lock(
                        fn(waiting: List<net.TcpStream>) {
                            let next: Option<net.TcpStream> = carrier.pop()
                            if !next.is_none() {
                                waiting.push((move next).expect(
                                    "handoff stream"))
                            }
                        })
                    // Flag after the push, wake after the flag: the drain the
                    // wake triggers must see both.
                    intakes[turn].flagged.store(true, MemoryOrder.release)
                    let woken: Result<bool> =
                        poll.wake(controls[turn].signal)
                    turn += 1
                    if turn >= worker_count { turn = 0 }
                }
            }
            err(problem) => { failed = some(problem) }
        }
    }

    // Stop every worker before judging the run: a dead acceptor with live
    // workers would strand the port half-served.
    for index: int in 0..controls.len() {
        if controls[index].signal >= 0 {
            let ignored: Result<bool> = controls[index].stop()
        }
    }
    for index: int in 0..workers.len() {
        let worker: Thread<Result<bool>> =
            workers.pop().expect("worker handle")
        match worker.join() {
            ok(_) => {}
            err(problem) => {
                if failed.is_none() { failed = some(problem) }
            }
        }
    }
    match failed {
        some(problem) => { return err(problem.msg, problem.kind) }
        none => {}
    }
    if startup_broken {
        return err("a worker failed before serving", "worker")
    }
    return ok(true)
}
