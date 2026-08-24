package espresso

import std.net
import std.thread
import std.time

// Every option a worker needs after binding, flattened into Send scalars.
struct WorkerLimits {
    backlog: int
    max_connections: int
    idle_timeout_ms: int
    graceful_shutdown_ms: int
    request_timeout_ms: int
    pending_timeout_ms: int
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
        let built: ServerOptions = new ServerOptions()
        built.host = host
        built.port = port
        built.backlog = self.backlog
        built.max_connections = self.max_connections
        built.idle_timeout_ms = self.idle_timeout_ms
        built.graceful_shutdown_ms = self.graceful_shutdown_ms
        built.request_timeout_ms = self.request_timeout_ms
        built.pending_timeout_ms = self.pending_timeout_ms
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
        idle_timeout_ms: options.idle_timeout_ms,
        graceful_shutdown_ms: options.graceful_shutdown_ms,
        request_timeout_ms: options.request_timeout_ms,
        pending_timeout_ms: options.pending_timeout_ms,
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

fn make_worker_app(
        factory: send fn() -> Result<WebApplication>,
        controls: Channel<Result<ServerControl>>) -> Result<WebApplication> {
    match factory() {
        err(problem) => {
            controls.send(err(problem.msg, problem.kind))
            return err(problem.msg, problem.kind)
        }
        ok(app) => { return ok(app) }
    }
}

fn build_worker_server(
        app: WebApplication,
        host: string,
        port: int,
        limits: WorkerLimits,
        streams: Channel<net.TcpStream>,
        wake: Channel<bool>,
        controls: Channel<Result<ServerControl>>) -> Result<WebServer> {
    let adopted: Result<WebServer> = WebServer.adopt_intake(
        app, limits.to_options(host, port), streams, wake)
    match adopted {
        err(problem) => {
            controls.send(err(problem.msg, problem.kind))
            return err(problem.msg, problem.kind)
        }
        ok(_) => {}
    }
    return ok((move adopted).expect("worker server"))
}

fn spawn_worker(
        host: string,
        port: int,
        limits: WorkerLimits,
        streams: Channel<net.TcpStream>,
        wake: Channel<bool>,
        controls: Channel<Result<ServerControl>>,
        finished: Channel<Result<bool>>,
        finished_signal: Atomic<bool>,
        shutdown: Atomic<bool>,
        move factory: send fn() -> Result<WebApplication>) ->
        Thread<Result<bool>> {
    return thread.spawn_async(
        send async fn() move(factory) -> Result<bool> {
            let app: WebApplication =
                make_worker_app(factory, controls)?
            let server: WebServer = build_worker_server(
                app, host, port, limits, streams, wake, controls)?
            let control: ServerControl = server.control()
            controls.send(ok(control))
            if shutdown.load(MemoryOrder.acquire) {
                let ignored_stop: Result<bool> = control.stop()
            }
            match await server.run() {
                ok(_) => {
                    finished.send(ok(true))
                    finished_signal.store(true, MemoryOrder.release)
                    return ok(true)
                }
                err(problem) => {
                    finished.send(err(problem.msg, problem.kind))
                    finished_signal.store(true, MemoryOrder.release)
                    return err(problem.msg, problem.kind)
                }
            }
        })
}

fn spawn_serve_cleanup(
        move workers: List<Thread<Result<bool>>>,
        controls: Channel<Result<ServerControl>>,
        finished: Channel<Result<bool>>,
        finished_signal: Atomic<bool>,
        shutdown: Atomic<bool>,
        ready: Channel<Result<bool>>,
        done: Channel<Result<bool>>,
        count: int) -> Thread<bool> {
    return thread.spawn(fn() move(workers) -> bool {
        var live_controls: List<ServerControl> = []
        var failed_message: string = ""
        var failed_kind: string = ""
        for index: int in 0..count {
            match controls.receive() {
                some(started) => {
                    match started {
                        ok(control) => { live_controls.push(control) }
                        err(problem) => {
                            if failed_message == "" {
                                failed_message = problem.msg
                                failed_kind = problem.kind
                            }
                        }
                    }
                }
                none => {
                    if failed_message == "" {
                        failed_message = "a worker failed before serving"
                        failed_kind = "worker"
                    }
                }
            }
        }

        if failed_message == "" {
            ready.send(ok(true))
            var worker_finished: bool = false
            for !shutdown.load(MemoryOrder.acquire) && !worker_finished {
                if finished_signal.load(MemoryOrder.acquire) {
                    worker_finished = true
                    match finished.receive() {
                        some(result) => {
                            match result {
                                ok(_) => {}
                                err(problem) => {
                                    failed_message = problem.msg
                                    failed_kind = problem.kind
                                }
                            }
                        }
                        none => {
                            failed_message =
                                "a worker stopped without a result"
                            failed_kind = "worker"
                        }
                    }
                } else {
                    time.sleep_millis(1)
                }
            }
        } else {
            ready.send(err(failed_message, failed_kind))
        }

        shutdown.store(true, MemoryOrder.release)
        for control: ServerControl in live_controls {
            let ignored_stop: Result<bool> = control.stop()
        }
        for workers.len() > 0 {
            let worker: Thread<Result<bool>> =
                workers.pop().expect("worker handle")
            match worker.join() {
                ok(_) => {}
                err(problem) => {
                    if failed_message == "" {
                        failed_message = problem.msg
                        failed_kind = problem.kind
                    }
                }
            }
        }
        if failed_message == "" {
            done.send(ok(true))
        } else {
            done.send(err(failed_message, failed_kind))
        }
        return true
    })
}

extern "C" fn beans_thread_parallelism() -> int

/// One worker per hardware thread, the way every serious server runtime
/// sizes itself. The probe never reports less than one.
pub fn recommended_workers() -> int {
    var count: int = 1
    unsafe { count = beans_thread_parallelism() }
    if count < 1 { return 1 }
    return count
}

/// Runs one async server per factory. With several factories, one acceptor
/// thread owns the listening socket and deals connections round-robin into
/// per-worker intake channels; workers keep independent app/service graphs.
pub async fn serve(
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
        await server.run()?
        return ok(true)
    }

    let count: int = factories.len()
    let limits: WorkerLimits = worker_limits(options)
    // One real listener, owned by a plain acceptor thread. SO_REUSEPORT
    // does not balance connections on macOS — every stream lands on one
    // listener — so the acceptor deals them round-robin into bounded
    // per-worker channels instead; a full worker back-pressures the
    // acceptor rather than dropping.
    let acceptor_listener: net.TcpListener =
        net.TcpListener.bind_with_backlog(
            options.host, options.port, options.backlog)?
    let port: int = acceptor_listener.port()?

    let shutdown: Atomic<bool> = new Atomic<bool>(false)
    let controls: Channel<Result<ServerControl>> = new Channel(count)
    let finished: Channel<Result<bool>> = new Channel(count)
    let finished_signal: Atomic<bool> = new Atomic<bool>(false)
    let ready: Channel<Result<bool>> = new Channel(1)
    let done: Channel<Result<bool>> = new Channel(1)
    var intakes: List<Channel<net.TcpStream>> = []
    var wakes: List<Channel<bool>> = []
    for index: int in 0..count {
        let intake: Channel<net.TcpStream> = new Channel(128)
        let wake: Channel<bool> = new Channel(1)
        intakes.push(intake)
        wakes.push(wake)
    }
    var workers: List<Thread<Result<bool>>> = []
    for index: int in 0..count {
        let factory: send fn() -> Result<WebApplication> =
            factories.pop().expect("worker factory")
        workers.push(spawn_worker(
            options.host, port, limits, intakes[index], wakes[index],
            controls, finished, finished_signal, shutdown, move factory))
    }
    let acceptor: Thread<bool> = spawn_acceptor(
        move acceptor_listener, count, shutdown,
        move intakes, move wakes)

    let cleanup: Thread<bool> = spawn_serve_cleanup(
        move workers, controls, finished, finished_signal,
        shutdown, ready, done, count)
    // defers run newest first: the store lands before the poke wakes
    // the blocking accept to observe it
    defer poke_acceptor(options.host, port)
    defer shutdown.store(true, MemoryOrder.release)

    match await ready.receive_async() {
        some(_) => {}
        none => {
            return err("the serve cleanup stopped before startup", "worker")
        }
    }
    let result: Result<bool> = match await done.receive_async() {
        some(completed) => completed,
        none => err("the serve cleanup stopped before completion", "worker"),
    }
    if !cleanup.join() {
        return err("the serve cleanup returned failure", "worker")
    }
    poke_acceptor(options.host, port)
    let acceptor_done: bool = acceptor.join()
    return result
}

/// A blocking accept cannot watch the shutdown flag, so stopping pokes
/// the listener with one throwaway connection to wake it.
fn poke_acceptor(host: string, port: int) {
    match net.TcpStream.connect(host, port) {
        ok(poke) => {
            let ignored: Result<bool> = poke.close()
        }
        err(_) => {}
    }
}

fn spawn_acceptor(
        move listener: net.TcpListener,
        count: int,
        shutdown: Atomic<bool>,
        move intakes: List<Channel<net.TcpStream>>,
        move wakes: List<Channel<bool>>) -> Thread<bool> {
    return thread.spawn(
        fn() move(listener, intakes, wakes) -> bool {
            var turn: int = 0
            for !shutdown.load(MemoryOrder.acquire) {
                var accepted: Result<net.TcpStream> = listener.accept()
                if !accepted.is_ok() {
                    // a handshake torn down while queued surfaces as a
                    // reset here; only a closed listener ends accepting
                    var closed_now: bool = false
                    match accepted {
                        err(problem) => {
                            closed_now = problem.kind == "closed"
                        }
                        ok(_) => {}
                    }
                    if closed_now { break }
                    continue
                }
                if shutdown.load(MemoryOrder.acquire) { break }
                let stream: net.TcpStream =
                    (move accepted).expect("accepted stream")
                intakes[turn].send(move stream)
                let nudged: bool = wakes[turn].try_send(true)
                turn += 1
                if turn >= count { turn = 0 }
            }
            let closed: Result<bool> = listener.close()
            for index: int in 0..count {
                intakes[index].close()
                wakes[index].close()
            }
            return true
        })
}
