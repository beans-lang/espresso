package main

// A request body that outgrew one read is released after its response, so a
// keep-alive connection does not keep its largest-ever body for life (resize(0)
// between requests frees no pages). The body's declared length is reserved once
// before the pieces arrive, so assembling it through a smaller read buffer does
// not regrow it. This drives real sockets: five POSTs whose 200 KB body is
// larger than the 64 KB read buffer, and two whose 1 KB body is not, and it
// reads back the server's count of buffers released — five, one per large body,
// none for the small ones. Reverting the release turns the count to zero; the
// handler echoing the body length proves every byte arrived before the release.

import espresso
import std.io
import std.net
import std.thread

const LARGE: int = 200000   // > the 64 KiB read buffer, so it is released
const SMALL: int = 1000     // one read's worth, so it is not
const LARGE_POSTS: int = 5
const SMALL_POSTS: int = 2

fn sink(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text_status(200, "{context.request.body.len()}")
}

fn body_of(n: int) -> string {
    let block: Bytes = new Bytes(0)
    block.reserve(1000)
    var i: int = 0
    for i < 1000 {
        block.push(97 + (i % 26))
        i += 1
    }
    let out: Bytes = new Bytes(0)
    out.reserve(n)
    var done: int = 0
    for done + 1000 <= n {
        out.append(block)
        done += 1000
    }
    for done < n {
        out.push(97 + ((done % 1000) % 26))
        done += 1
    }
    return out.to_string()
}

// One POST on its own connection, Connection: close. Returns the response body,
// which the handler set to the received body's length.
fn post_once(port: int, body: string) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            let armed: Result<bool> = stream.set_timeouts(8000, 8000)
            let req: string =
                "POST /sink HTTP/1.1\r\nHost: a\r\nContent-Length: {body.len()}\r\nConnection: close\r\n\r\n{body}"
            match stream.write_text(req) {
                ok(_) => {}
                err(error) => { return "write-failed" }
            }
            let raw: string =
                stream.read_to_end(65536).or(new Bytes(0)).to_string()
            match raw.find("\r\n\r\n") {
                some(at) => { return raw.slice(at + 4, raw.len()) }
                none => { return "no-head" }
            }
        }
        err(error) => { return "connect-failed" }
    }
}

fn client(port: int, control: espresso.ServerControl) -> string {
    let big: string = body_of(LARGE)
    let small: string = body_of(SMALL)
    var large_ok: int = 0
    var small_ok: int = 0
    var index: int = 0
    for index < LARGE_POSTS {
        if post_once(port, big) == "{LARGE}" { large_ok += 1 }
        index += 1
    }
    index = 0
    for index < SMALL_POSTS {
        if post_once(port, small) == "{SMALL}" { small_ok += 1 }
        index += 1
    }
    let stopped: bool = control.stop().or(false)
    return "large_ok {large_ok} small_ok {small_ok} stopped {stopped}"
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.post("/sink", sink).expect("route")

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
    io.println("released {stats.request_buffers_released} presized {stats.request_bodies_presized} requests {stats.requests}")
}
