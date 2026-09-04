package main

// Issue #3, the deferred-response half. A handler that takes a Responder with
// respond_later() and then panics on the connection fiber abandons the
// Responder in the unwind. Without a signal, the connection fiber would sit in
// await_completion until pending_timeout_ms (a DoS-shaped stall). Responder's
// deinit sends a sentinel when it is dropped unanswered, so the waiter wakes at
// once with a 500 instead.
//
//   with the fix:            deferred-panic 500 true 503 false stood true
//   without it (reverted):   deferred-panic 500 false 503 true stood true
//
// pending_timeout_ms is set low so the reverted (timeout) path still finishes
// quickly; at the 30s default, the reverted behaviour is a 30s stall per
// abandoned request. Both backends must agree.

import espresso
import std.io
import std.net
import std.thread

fn calm(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("calm")
}

fn deferred_boom(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let responder: espresso.Responder = context.respond_later()?
    // The handler takes the responder and then dies before handing it to a
    // worker: the responder is dropped in the unwind, unanswered.
    panic("panicked while holding the responder")
    return espresso.detached()
}

fn request(port: int, target: string) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            match stream.write_text(
                    "GET {target} HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n") {
                ok(_) => {}
                err(error) => { return "write-failed {error.kind}" }
            }
            return stream.read_to_end(65536).or(new Bytes(0)).to_string()
        }
        err(error) => { return "connect-failed {error.kind}" }
    }
}

fn client(port: int, control: espresso.ServerControl) -> string {
    let reply: string = request(port, "/deferred_boom")
    let got_500: bool = reply.contains("500 Internal Server Error")
    let got_503: bool = reply.contains("503 Service Unavailable")

    let after: string = request(port, "/calm")
    let stood: bool = after.contains("200 OK") && after.contains("calm")

    let stopped: bool = control.stop().or(false)
    return "deferred-panic 500 {got_500} 503 {got_503} stood {stood} stopped {stopped}"
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/calm", calm).expect("route")
    app.get("/deferred_boom", deferred_boom).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 25
    options.pending_timeout_ms = 500
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println(visitor.join())
}
