package main

import espresso
import std.async as aio
import std.io
import std.net
import std.thread
import std.time

class ServerDrop {
    dropped: Atomic<int>

    fn init(dropped: Atomic<int>) { self.dropped = dropped }

    fn deinit() { self.dropped.fetch_add(1, MemoryOrder.relaxed) }
}

async fn run_owned(move server: espresso.WebServer,
                   started: Channel<bool>) -> bool {
    started.send(true)
    match await server.run() {
        ok(_) => { return true }
        err(_) => { return false }
    }
}

fn instantiate_server_drop(app: espresso.WebApplication) -> Result<bool> {
    let held: ServerDrop = app.services.resolve<ServerDrop>()?
    return ok(true)
}

fn request(port: int, target: string) -> string {
    let stream: net.TcpStream = net.TcpStream.connect_timeout(
        "127.0.0.1", port, 3000).expect("connect")
    stream.write_text(
        "GET {target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .expect("write")
    return stream.read_to_end(65536).expect("read").to_string()
}

fn isolation_client(port: int,
                    control: espresso.ServerControl,
                    started: Channel<bool>,
                    release: aio.Event) -> string {
    let slow: net.TcpStream = net.TcpStream.connect_timeout(
        "127.0.0.1", port, 3000).expect("slow connect")
    slow.write_text(
        "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .expect("slow write")
    started.receive().expect("slow started")
    let fast_started: int = time.monotonic_nanos()
    let fast: string = request(port, "/fast")
    let fast_elapsed: int = time.monotonic_nanos() - fast_started
    time.sleep_millis(500)
    release.set()
    let slow_reply: string =
        slow.read_to_end(65536).expect("slow read").to_string()
    control.stop().expect("stop")
    return "fast {fast.ends_with("fast")} under100 {fast_elapsed < 100000000} slow {slow_reply.ends_with("slow")}"
}

async fn isolation() -> Result<bool> {
    let started: Channel<bool> = new Channel(1)
    let release: aio.Event = new aio.Event()
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get("/slow", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        started.send(true)
        await release.wait()
        return espresso.text("slow")
    })?
    app.get_sync("/fast", fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        return espresso.text("fast")
    })?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    let port: int = server.port()?
    let control: espresso.ServerControl = server.control()
    let client: Thread<string> = thread.spawn(fn() -> string {
        return isolation_client(port, control, started, release)
    })
    let stats: espresso.ServerStats = await server.run()?
    let isolation: string = (await client.join_async())?
    io.println("isolation {isolation} peak {stats.active_peak}")
    return ok(true)
}

fn graceful_client(port: int,
                   control: espresso.ServerControl,
                   started: Channel<bool>,
                   release: aio.Event) -> string {
    let stream: net.TcpStream = net.TcpStream.connect_timeout(
        "127.0.0.1", port, 3000).expect("connect")
    stream.write_text(
        "GET /work HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .expect("write")
    started.receive().expect("started")
    control.stop().expect("stop")
    time.sleep_millis(50)
    var refused: bool = false
    match net.TcpStream.connect_timeout("127.0.0.1", port, 100) {
        ok(unwanted) => {
            let ignored: Result<bool> = unwanted.close()
        }
        err(_) => { refused = true }
    }
    release.set()
    let completed: bool = stream.read_to_end(65536).expect("read").to_string()
        .ends_with("finished")
    return "completed {completed} refused {refused}"
}

async fn graceful_completion() -> Result<bool> {
    let started: Channel<bool> = new Channel(1)
    let release: aio.Event = new aio.Event()
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get("/work", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        started.send(true)
        await release.wait()
        return espresso.text("finished")
    })?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.graceful_shutdown_ms = 500
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    let port: int = server.port()?
    let control: espresso.ServerControl = server.control()
    let client: Thread<string> = thread.spawn(fn() -> string {
        return graceful_client(port, control, started, release)
    })
    let stats: espresso.ServerStats = await server.run()?
    let graced: string = (await client.join_async())?
    io.println(
        "grace {graced} responses {stats.responses}")
    return ok(true)
}

fn forced_client(port: int,
                 control: espresso.ServerControl,
                 started: Channel<bool>) -> bool {
    let stream: net.TcpStream = net.TcpStream.connect_timeout(
        "127.0.0.1", port, 3000).expect("connect")
    stream.write_text(
        "GET /park HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .expect("write")
    started.receive().expect("started")
    control.stop().expect("stop")
    let response: string =
        stream.read_to_end(65536).or(new Bytes(0)).to_string()
    return !response.contains("200 OK")
}

async fn forced_shutdown() -> Result<bool> {
    let started: Channel<bool> = new Channel(1)
    let canceled: aio.Event = new aio.Event()
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get("/park", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        defer canceled.set()
        started.send(true)
        await aio.sleep_millis(10000)
        return espresso.text("late")
    })?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.graceful_shutdown_ms = 25
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    let port: int = server.port()?
    let control: espresso.ServerControl = server.control()
    let client: Thread<bool> = thread.spawn(fn() -> bool {
        return forced_client(port, control, started)
    })
    let stats: espresso.ServerStats = await server.run()?
    let closed: bool = (await client.join_async())?
    io.println(
        "forced canceled {canceled.is_set()} closed {closed} responses {stats.responses}")
    return ok(true)
}

async fn stopped_before_run() -> Result<bool> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    server.control().stop()?
    let stats: espresso.ServerStats = await server.run()?
    io.println("pre-stopped accepted {stats.accepted}")
    return ok(true)
}

fn timeout_client(port: int, control: espresso.ServerControl) -> int {
    let response: string = request(port, "/wait")
    control.stop().expect("stop")
    if response.contains("503 Service Unavailable") { return 503 }
    if response.contains("200 OK") { return 200 }
    return 0
}

async fn timeout_case(request_timeout_ms: int,
                      pending_timeout_ms: int,
                      delay_ms: int) -> Result<int> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get("/wait", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        await aio.sleep_millis(delay_ms)
        return espresso.text("ready")
    })?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.request_timeout_ms = request_timeout_ms
    options.pending_timeout_ms = pending_timeout_ms
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    let port: int = server.port()?
    let control: espresso.ServerControl = server.control()
    let client: Thread<int> = thread.spawn(fn() -> int {
        return timeout_client(port, control)
    })
    let ignored: espresso.ServerStats = await server.run()?
    return await client.join_async()
}

fn partial_timeout_client(port: int,
                          control: espresso.ServerControl) -> bool {
    let response: string = request(port, "/partial")
    control.stop().expect("stop")
    return response.contains("503 Service Unavailable") &&
        !response.contains("200 OK") && !response.contains("partial")
}

async fn partial_timeout() -> Result<bool> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get("/partial", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        context.response.text(200, "OK", "partial")
        await aio.sleep_millis(75)
        return espresso.detached()
    })?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.request_timeout_ms = 25
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    let port: int = server.port()?
    let control: espresso.ServerControl = server.control()
    let client: Thread<bool> = thread.spawn(fn() -> bool {
        return partial_timeout_client(port, control)
    })
    let ignored: espresso.ServerStats = await server.run()?
    return await client.join_async()
}

async fn canceled_run() -> Result<string> {
    let dropped: Atomic<int> = new Atomic<int>(0)
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_singleton_factory<ServerDrop>(
        builder.services,
        fn(provider: espresso.ServiceProvider) -> Result<ServerDrop> {
            return ok(new ServerDrop(dropped))
        })?
    let app: espresso.WebApplication = builder.build()?
    instantiate_server_drop(app)?
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
    let port: int = server.port()?
    let started: Channel<bool> = new Channel(1)
    let running: aio.TaskGroup<bool> = new aio.TaskGroup<bool>()
    running.start(run_owned(move server, started))
    let ignored_running: Option<bool> = running.try_next()
    (await started.receive_async()).expect("run started")
    running.cancel_all()

    var refused: bool = false
    match net.TcpStream.connect_timeout("127.0.0.1", port, 100) {
        ok(unwanted) => {
            let ignored_close: Result<bool> = unwanted.close()
        }
        err(_) => { refused = true }
    }
    return ok(
        "refused {refused} dropped {dropped.load(MemoryOrder.relaxed)}")
}

async fn main() {
    (await isolation()).expect("isolation")
    (await graceful_completion()).expect("grace")
    (await forced_shutdown()).expect("forced")
    (await stopped_before_run()).expect("pre-stopped")
    let old_only: int = (await timeout_case(0, 25, 75)).expect("old timeout")
    let new_wins: int = (await timeout_case(150, 25, 75)).expect("new timeout")
    io.println("timeouts old {old_only} new {new_wins}")
    let partial: bool = (await partial_timeout()).expect("partial")
    io.println("partial timeout {partial}")
    let cancel_ran: string = (await canceled_run()).expect("cancel run")
    io.println("cancel run {cancel_ran}")
}
