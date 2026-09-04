package main

// Issue #3, the espresso-level proof of reclamation. Containment (a 500 comes
// back, the server stands) is proved by panic.b; this proves that a contained
// panic actually RECLAIMS what the request held, over a count large enough to
// matter (n=1 proves nothing). Each /boom handler bumps a depth counter, arms a
// `defer` that decrements it, owns a local whose `deinit` counts a released
// resource, and then panics. If the runtime unwind reclaims the frame:
//
//   - the defer runs, so depth returns to 0 across all 100 panics,
//   - the local's deinit runs, so the resource count equals the request count,
//   - and the connection closes after each panic (the server's policy), while
//   - the server keeps serving (a final /calm answers 200).
//
// This is a native-codegen feature (the unwind pads), so the harness runs this
// file on the native backend too, not only the interpreter — see test.sh.

import espresso
import std.io
import std.net
import std.thread

fn boom_count() -> int { return 100 }

// Process-wide counters, reachable from the handler (on a brewed fiber) and
// from main after the server returns. Atomics because a worker could in
// principle run the handler off the main fiber; the values are read only after
// run() returns, when every fiber is done.
singleton class Tally {
    depth: Atomic<int> = new Atomic<int>(0)
    deinits: Atomic<int> = new Atomic<int>(0)

    fn enter() { self.depth.fetch_add(1, MemoryOrder.relaxed) }
    fn leave() { self.depth.fetch_sub(1, MemoryOrder.relaxed) }
    fn dropped() { self.deinits.fetch_add(1, MemoryOrder.relaxed) }
    fn depth_now() -> int { return self.depth.load(MemoryOrder.relaxed) }
    fn deinits_now() -> int { return self.deinits.load(MemoryOrder.relaxed) }
}

// A resource the request owns. Its deinit must run when the panicking frame
// unwinds, exactly as it would on a normal return.
class Guard {
    fn init() {}
    fn deinit() { Tally.instance.dropped() }
}

fn calm(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("calm")
}

fn boom(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    Tally.instance.enter()
    let guard: Guard = new Guard()
    defer Tally.instance.leave()
    panic("the handler lost it")
    return espresso.text("never reached")
}

fn client(port: int, control: espresso.ServerControl) -> string {
    var contained: int = 0
    var closed: int = 0
    var index: int = 0
    for index < boom_count() {
        index += 1
        match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
            ok(stream) => {
                // Keep-alive request on purpose: the server's panic policy,
                // not the client, must close the connection.
                match stream.write_text(
                        "GET /boom HTTP/1.1\r\nHost: a\r\n\r\n") {
                    ok(_) => {}
                    err(error) => {
                        let ignored: Result<bool> = control.stop()
                        return "boom write failed {error.kind}"
                    }
                }
                let reply: string =
                    stream.read_to_end(65536).or(new Bytes(0)).to_string()
                if reply.contains("500 Internal Server Error") {
                    contained += 1
                }
                if reply.contains("Connection: close") { closed += 1 }
            }
            err(error) => {
                let ignored: Result<bool> = control.stop()
                return "boom connect failed {error.kind}"
            }
        }
    }

    // The server must still be standing for ordinary traffic.
    var stood: bool = false
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            match stream.write_text(
                    "GET /calm HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n") {
                ok(_) => {}
                err(error) => {
                    let ignored: Result<bool> = control.stop()
                    return "calm write failed {error.kind}"
                }
            }
            let after: string =
                stream.read_to_end(65536).or(new Bytes(0)).to_string()
            stood = after.contains("200 OK") && after.contains("calm")
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "calm connect failed {error.kind}"
        }
    }

    let stopped: bool = control.stop().or(false)
    return "contained {contained} closed {closed} stood {stood} stopped {stopped}"
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/calm", calm).expect("route")
    app.get("/boom", boom).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 25
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println(visitor.join())
    io.println("depth {Tally.instance.depth_now()} deinits {Tally.instance.deinits_now()}")
}
