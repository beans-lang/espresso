package main

import espresso
import std.async as aio
import std.io
import std.net
import std.thread
import std.time

class WorkerDrop {
    dropped: Atomic<int>

    fn init(dropped: Atomic<int>) { self.dropped = dropped }

    fn deinit() { self.dropped.fetch_add(1, MemoryOrder.relaxed) }
}

fn instantiate_worker_drop(app: espresso.WebApplication) -> Result<bool> {
    let held: WorkerDrop = app.services.resolve<WorkerDrop>()?
    return ok(true)
}

fn live_app() -> Result<espresso.WebApplication> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    return builder.build()
}

fn failed_app() -> Result<espresso.WebApplication> {
    return err("planned worker startup failure", "startup")
}

fn counted_app(started: Atomic<int>,
               dropped: Atomic<int>) -> Result<espresso.WebApplication> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_singleton_factory<WorkerDrop>(
        builder.services,
        fn(provider: espresso.ServiceProvider) -> Result<WorkerDrop> {
            return ok(new WorkerDrop(dropped))
        })?
    let app: espresso.WebApplication = builder.build()?
    instantiate_worker_drop(app)?
    app.get_sync("/", fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        return espresso.text("live")
    })?
    started.fetch_add(1, MemoryOrder.relaxed)
    return ok(app)
}

async fn run_live(options: espresso.ServerOptions,
                  move factories: List<send fn() ->
                      Result<espresso.WebApplication>>) -> bool {
    match await espresso.serve(options, move factories) {
        ok(_) => { return true }
        err(_) => { return false }
    }
}

fn request_when_ready(port: int) -> bool {
    for attempt: int in 0..3000 {
        match net.TcpStream.connect_timeout("127.0.0.1", port, 10) {
            ok(stream) => {
                stream.write_text(
                    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    .expect("write")
                let response: string = stream.read_to_end(65536)
                    .expect("read").to_string()
                return response.contains("200 OK") &&
                    response.ends_with("live")
            }
            err(_) => { time.sleep_millis(1) }
        }
    }
    return false
}

fn listener_eventually_refuses(port: int) -> bool {
    for attempt: int in 0..3000 {
        match net.TcpStream.connect_timeout("127.0.0.1", port, 10) {
            ok(stream) => {
                let ignored_close: Result<bool> = stream.close()
                time.sleep_millis(1)
            }
            err(_) => { return true }
        }
    }
    return false
}

async fn successful_workers() -> Result<string> {
    let probe: net.TcpListener =
        net.TcpListener.bind("127.0.0.1", 0)?
    let port: int = probe.port()?
    probe.close()?

    let started: Atomic<int> = new Atomic<int>(0)
    let dropped: Atomic<int> = new Atomic<int>(0)
    var factories: List<send fn() -> Result<espresso.WebApplication>> = []
    factories.push(send fn() -> Result<espresso.WebApplication> {
        return counted_app(started, dropped)
    })
    factories.push(send fn() -> Result<espresso.WebApplication> {
        return counted_app(started, dropped)
    })
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = port
    let running: aio.TaskGroup<bool> = new aio.TaskGroup<bool>()
    running.start(run_live(options, move factories))
    let ignored_running: Option<bool> = running.try_next()
    let client: Thread<bool> = thread.spawn(fn() -> bool {
        return request_when_ready(port)
    })
    let served: bool = (await client.join_async())?
    running.cancel_all()

    var drop_waits: int = 0
    for dropped.load(MemoryOrder.relaxed) < 2 && drop_waits < 3000 {
        drop_waits += 1
        await aio.sleep_millis(1)
    }
    let refused: bool = listener_eventually_refuses(port)
    return ok(
        "served {served} workers {started.load(MemoryOrder.relaxed)} dropped {dropped.load(MemoryOrder.relaxed)} refused {refused}")
}

async fn main() {
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    var factories: List<send fn() -> Result<espresso.WebApplication>> = []
    factories.push(live_app)
    factories.push(failed_app)
    match await espresso.serve(options, move factories) {
        ok(_) => { io.println("serve unexpectedly succeeded") }
        err(problem) => { io.println("serve stopped {problem.kind}") }
    }
    io.println("serve live {(await successful_workers()).expect("workers")}")
}
