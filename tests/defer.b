package main

import espresso
import std.async as aio
import std.io
import std.net
import std.thread
import std.time

fn fast(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("fast")
}

fn client(port: int, control: espresso.ServerControl) -> string {
    // One pipelined burst: two async requests sit between two synchronous
    // ones, and every response must come back in request order.
    var burst: string = "burst-broken"
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            match stream.write_text(
                    "GET /fast HTTP/1.1\r\nHost: a\r\n\r\nGET /slow HTTP/1.1\r\nHost: a\r\n\r\nGET /twice HTTP/1.1\r\nHost: a\r\n\r\nGET /fast HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n") {
                ok(_) => {}
                err(error) => {
                    let ignored: Result<bool> = control.stop()
                    return "burst write failed {error.kind}"
                }
            }
            let response: string =
                stream.read_to_end(65536).or(new Bytes(0)).to_string()
            let parts: List<string> = response.split("HTTP/1.1 200 OK")
            var ordered: bool = false
            if parts.len() == 5 {
                ordered = parts[1].ends_with("fast") &&
                    parts[2].ends_with("slow") &&
                    parts[3].ends_with("one") &&
                    parts[4].ends_with("fast")
            }
            burst = "burst {ordered}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "burst connect failed {error.kind}"
        }
    }

    // A handler beyond the request deadline must reply 503 and close.
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(second) => {
            match second.write_text(
                    "GET /drop HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n") {
                ok(_) => {}
                err(error) => {
                    let ignored: Result<bool> = control.stop()
                    return "drop write failed {error.kind}"
                }
            }
            let reply: string =
                second.read_to_end(65536).or(new Bytes(0)).to_string()
            let timed: bool =
                reply.contains("503 Service Unavailable") &&
                reply.contains("timed out")
            let stopped: bool = control.stop().or(false)
            return "{burst} timeout {timed} stopped {stopped}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "drop connect failed {error.kind}"
        }
    }
}

async fn main() {
    let pool: espresso.WorkerPool =
        espresso.WorkerPool.start(2).expect("pool")
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get_sync("/fast", fast).expect("route")
    app.get("/slow", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        let body: string = await pool.execute(send fn() -> string {
            time.sleep_millis(50)
            return "slow"
        })?
        return espresso.text(body)
    }).expect("route")
    app.get("/twice", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        let body: string = await pool.execute(send fn() -> string {
            return "one"
        })?
        return espresso.text(body)
    }).expect("route")
    app.get("/drop", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        await aio.sleep_millis(900)
        return espresso.text("late")
    }).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.request_timeout_ms = 200
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = (await server.run()).expect("run")
    io.println((await visitor.join_async()).expect("visitor"))
    io.println("accepted {stats.accepted} requests {stats.requests} responses {stats.responses} errors {stats.connection_errors}")
    (await pool.close()).expect("pool close")
}
