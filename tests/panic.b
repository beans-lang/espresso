package main

import espresso
import std.io
import std.net
import std.thread

fn calm(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("calm")
}

// The drill: a handler that panics must cost its request a 500, never the
// server. The shield fiber contains the panic and the join turns it into
// the error the 500 is written from.
fn moody(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    panic("the handler lost it")
    return espresso.text("never reached")
}

fn client(port: int, control: espresso.ServerControl) -> string {
    var drill: string = "drill-broken"
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(first) => {
            match first.write_text(
                    "GET /boom HTTP/1.1\r\nHost: a\r\n\r\n") {
                ok(_) => {}
                err(error) => {
                    let ignored: Result<bool> = control.stop()
                    return "drill write failed {error.kind}"
                }
            }
            let reply: string =
                first.read_to_end(65536).or(new Bytes(0)).to_string()
            let contained: bool =
                reply.contains("500 Internal Server Error") &&
                reply.contains("the handler lost it")
            // The panic response closes its connection; read_to_end only
            // returns because it did.
            drill = "drill {contained}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "drill connect failed {error.kind}"
        }
    }

    // The server must still be standing for ordinary traffic.
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(second) => {
            match second.write_text(
                    "GET /calm HTTP/1.1\r\nHost: a\r\n\r\nGET /calm HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n") {
                ok(_) => {}
                err(error) => {
                    let ignored: Result<bool> = control.stop()
                    return "calm write failed {error.kind}"
                }
            }
            let after: string =
                second.read_to_end(65536).or(new Bytes(0)).to_string()
            let served: bool =
                after.split("HTTP/1.1 200 OK").len() == 3 &&
                after.contains("calm")
            let stopped: bool = control.stop().or(false)
            return "{drill} stood {served} stopped {stopped}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "calm connect failed {error.kind}"
        }
    }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/calm", calm).expect("route")
    app.get("/boom", moody).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
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
}
