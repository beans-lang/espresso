package main

import espresso
import std.io
import std.net
import std.thread
import std.time

fn fast(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("fast")
}

fn client(port: int, control: espresso.ServerControl) -> string {
    // One pipelined burst: two deferred requests sit between two synchronous
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

    // A handler that never answers: the pending timeout must reply 503 and
    // close, and the responder that fires later must vanish without effect.
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
            // Give the late responder time to fire against the still-running
            // server before stopping it.
            time.sleep_millis(900)
            let stopped: bool = control.stop().or(false)
            return "{burst} timeout {timed} stopped {stopped}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "drop connect failed {error.kind}"
        }
    }
}

fn main() {
    let pool: espresso.WorkerPool =
        espresso.WorkerPool.start(2).expect("pool")
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/fast", fast).expect("route")
    app.get("/slow", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        let responder: espresso.Responder = context.respond_later()?
        pool.submit(fn() move(responder) {
            time.sleep_millis(50)
            let sent: Result<bool> = responder.text(200, "OK", "slow")
        })?
        return espresso.detached()
    }).expect("route")
    app.get("/twice", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        let responder: espresso.Responder = context.respond_later()?
        pool.submit(fn() move(responder) {
            let first: Result<bool> = responder.text(200, "OK", "one")
            // The second send must be refused by the one-shot flag.
            let refused: Result<bool> = responder.text(200, "OK", "two")
        })?
        return espresso.detached()
    }).expect("route")
    app.get("/drop", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        let responder: espresso.Responder = context.respond_later()?
        pool.submit(fn() move(responder) {
            time.sleep_millis(900)
            let late: Result<bool> = responder.text(200, "OK", "late")
        })?
        return espresso.detached()
    }).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    options.pending_timeout_ms = 200
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println(visitor.join())
    io.println("accepted {stats.accepted} requests {stats.requests} responses {stats.responses} errors {stats.connection_errors}")
    pool.close().expect("pool close")
}
