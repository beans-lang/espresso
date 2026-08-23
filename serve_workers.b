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

fn spawn_worker(
        host: string,
        port: int,
        limits: WorkerLimits,
        move listener: net.TcpListener,
        controls: Channel<Result<ServerControl>>,
        finished: Channel<Result<bool>>,
        shutdown: Atomic<bool>,
        move factory: send fn() -> Result<WebApplication>) ->
        Thread<Result<bool>> {
    return thread.spawn_async(
        send async fn() move(factory, listener) -> Result<bool> {
            match factory() {
                err(problem) => {
                    await controls.send_async(err(
                        problem.msg, problem.kind))
                    return err(problem.msg, problem.kind)
                }
                ok(app) => {
                    match WebServer.adopt(
                            app, limits.to_options(host, port),
                            move listener) {
                        err(problem) => {
                            await controls.send_async(err(
                                problem.msg, problem.kind))
                            return err(problem.msg, problem.kind)
                        }
                        ok(server) => {
                            let control: ServerControl = server.control()
                            await controls.send_async(ok(control))
                            if shutdown.load(MemoryOrder.acquire) {
                                let ignored_stop: Result<bool> = control.stop()
                            }
                            match await server.run() {
                                ok(_) => {
                                    finished.send(ok(true))
                                    return ok(true)
                                }
                                err(problem) => {
                                    finished.send(err(
                                        problem.msg, problem.kind))
                                    return err(problem.msg, problem.kind)
                                }
                            }
                        }
                    }
                }
            }
        })
}

fn spawn_serve_cleanup(
        move workers: List<Thread<Result<bool>>>,
        controls: Channel<Result<ServerControl>>,
        finished: Channel<Result<bool>>,
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
                match finished.try_receive() {
                    some(result) => {
                        worker_finished = true
                        match result {
                            ok(_) => {}
                            err(problem) => {
                                failed_message = problem.msg
                                failed_kind = problem.kind
                            }
                        }
                    }
                    none => { time.sleep_millis(1) }
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

/// The default remains one worker. Add workers only after measuring a
/// CPU-bound application on its target platform.
pub fn recommended_workers() -> int { return 1 }

/// Runs one async server per factory. With several factories, workers bind
/// the same port through SO_REUSEPORT and keep independent app/service graphs.
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
    let first: net.TcpListener = net.TcpListener.bind_reuse_port_with_backlog(
        options.host, options.port, options.backlog)?
    let port: int = first.port()?
    var listeners: List<net.TcpListener> = []
    listeners.push(move first)
    for index: int in 1..count {
        listeners.push(net.TcpListener.bind_reuse_port_with_backlog(
            options.host, port, options.backlog)?)
    }

    let shutdown: Atomic<bool> = new Atomic<bool>(false)
    let controls: Channel<Result<ServerControl>> = new Channel(count)
    let finished: Channel<Result<bool>> = new Channel(count)
    let ready: Channel<Result<bool>> = new Channel(1)
    let done: Channel<Result<bool>> = new Channel(1)
    var workers: List<Thread<Result<bool>>> = []
    for index: int in 0..count {
        let factory: send fn() -> Result<WebApplication> =
            factories.pop().expect("worker factory")
        let listener: net.TcpListener = listeners.pop().expect("worker listener")
        workers.push(spawn_worker(
            options.host, port, limits, move listener,
            controls, finished, shutdown, move factory))
    }

    let cleanup: Thread<bool> = spawn_serve_cleanup(
        move workers, controls, finished, shutdown, ready, done, count)
    defer shutdown.store(true, MemoryOrder.release)

    match await ready.receive_async() {
        some(_) => {}
        none => {
            return err("the serve cleanup stopped before startup", "worker")
        }
    }
    let result: Result<bool> = match await done.receive_async() {
        some(completed) => { completed }
        none => {
            err("the serve cleanup stopped before completion", "worker")
        }
    }
    if !cleanup.join() {
        return err("the serve cleanup returned failure", "worker")
    }
    return result
}
