package main

// The resident-memory gate for the borrowed-body work (server.b / http.b /
// results.b). It holds 32 keep-alive connections open, each having been served
// one 1 MiB response, and then parks so an outside observer can read the
// process's RSS while all 32 are live. tests/rss_gate.sh drives it: it waits
// for the "ready" marker, reads `ps -o rss=`, checks it against a threshold,
// then writes a line to stdin to let this program release the connections and
// exit.
//
// Why it measures what it measures: a connection's HttpResponse.body keeps the
// capacity it grew to (resize(0) between requests frees no pages), so before
// the body is borrowed every one of the 32 connections retains a megabyte —
// ~32 MiB, which is the bulk of the ~38.8 MiB the /static1m ledger row reports
// under wrk -c32. The clients drain each response through a small reused buffer
// and never hold a megabyte themselves, so the resident set is the server's.
//
// Native only: under the tree interpreter the process is the whole compiler and
// its baseline RSS dwarfs the thing under test, so rss_gate.sh builds and
// measures the native binary.

import espresso
import std.io
import std.net
import std.thread
import std.time

const BODY_BYTES: int = 1048576   // 1 MiB
const CLIENTS: int = 32
const SCRATCH: int = 16384        // the client's whole receive footprint

// Process-wide coordination between the client threads, the coordinator, and
// the outside driver. Atomics because these cells are touched from 33 threads.
singleton class RssCoord {
    arrived: Atomic<int> = new Atomic<int>(0)
    failed: Atomic<int> = new Atomic<int>(0)
    release: Atomic<bool> = new Atomic<bool>(false)

    fn arrive() { self.arrived.fetch_add(1, MemoryOrder.acq_rel) }
    fn fail() { self.failed.fetch_add(1, MemoryOrder.acq_rel) }
    fn arrived_now() -> int { return self.arrived.load(MemoryOrder.acquire) }
    fn failed_now() -> int { return self.failed.load(MemoryOrder.acquire) }
    fn total() -> int {
        return self.arrived.load(MemoryOrder.acquire) +
               self.failed.load(MemoryOrder.acquire)
    }
    fn release_all() { self.release.store(true, MemoryOrder.release) }
    fn wait_release() {
        for !self.release.load(MemoryOrder.acquire) {
            time.sleep_millis(2)
        }
    }
}

fn make_body(n: int) -> string {
    let block: Bytes = new Bytes(0)
    block.reserve(1024)
    var i: int = 0
    for i < 1024 {
        block.push(65 + (i % 26))
        i += 1
    }
    let out: Bytes = new Bytes(0)
    out.reserve(n)
    var done: int = 0
    for done + 1024 <= n {
        out.append(block)
        done += 1024
    }
    for done < n {
        out.push(65)
        done += 1
    }
    return out.to_string()
}

fn head_end_of(resp: Bytes) -> int {
    var i: int = 0
    let n: int = resp.len()
    for i + 4 <= n {
        if resp.get_u8(i) == 13 && resp.get_u8(i + 1) == 10 &&
           resp.get_u8(i + 2) == 13 && resp.get_u8(i + 3) == 10 {
            return i
        }
        i += 1
    }
    return -1
}

fn clen_from(head: string) -> int {
    let needle: string = "\r\nContent-Length: "
    match head.find(needle) {
        some(at) => {
            let start: int = at + needle.len()
            let rest: string = head.slice(start, head.len())
            match rest.find("\r\n") {
                some(rel) => { return rest.slice(0, rel).to_int().or(-1) }
                none => { return -1 }
            }
        }
        none => { return -1 }
    }
}

// Fetch one 1 MiB response, draining the body through a reused 16 KiB buffer so
// this thread never holds a megabyte, then hold the connection open until the
// driver releases it.
fn client(port: int) -> int {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 5000) {
        ok(stream) => {
            let armed: Result<bool> = stream.set_timeouts(20000, 20000)
            match stream.write_text("GET /big HTTP/1.1\r\nHost: a\r\n\r\n") {
                ok(_) => {}
                err(error) => { RssCoord.instance.fail(); return 1 }
            }
            let scratch: Bytes = Bytes.filled(SCRATCH, 0)
            var head: Bytes = new Bytes(0)
            var clen: int = -1
            var body_start: int = -1
            for body_start < 0 {
                match stream.read_into(scratch) {
                    ok(got) => {
                        if got == 0 { RssCoord.instance.fail(); return 2 }
                        head.append_range(scratch, 0, got)
                        let he: int = head_end_of(head)
                        if he >= 0 {
                            body_start = he + 4
                            clen = clen_from(head.slice(0, he).to_string())
                        }
                    }
                    err(error) => { RssCoord.instance.fail(); return 3 }
                }
            }
            if clen < 0 { RssCoord.instance.fail(); return 4 }
            var have: int = head.len() - body_start
            for have < clen {
                match stream.read_into(scratch) {
                    ok(got) => {
                        if got == 0 { RssCoord.instance.fail(); return 5 }
                        have += got
                    }
                    err(error) => { RssCoord.instance.fail(); return 6 }
                }
            }
            RssCoord.instance.arrive()
            RssCoord.instance.wait_release()
            let closed: Result<bool> = stream.close()
            return 0
        }
        err(error) => { RssCoord.instance.fail(); return 7 }
    }
}

// Waits for all 32 to be holding, prints the marker the driver waits on, then
// blocks on stdin. When the driver has read RSS and answers, releases the
// connections and stops the server.
fn coordinate(control: espresso.ServerControl) -> int {
    for RssCoord.instance.total() < CLIENTS {
        time.sleep_millis(5)
    }
    // The marker goes to stderr: stdout is fully buffered when redirected to a
    // file, so a stdout marker would not reach the driver until the process
    // exits — which is after the driver's input, a deadlock. stderr is
    // unbuffered, so the driver sees "ready" the moment all 32 are holding.
    io.eprintln("ready arrived {RssCoord.instance.arrived_now()} failed {RssCoord.instance.failed_now()}")
    let line: Option<string> = io.read_line()
    RssCoord.instance.release_all()
    let stopped: Result<bool> = control.stop()
    return 0
}

fn map_big(app: espresso.WebApplication, body: string) -> Result<bool> {
    return app.get(
        "/big",
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return espresso.text_status(200, body)
        })
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_big(app, make_body(BODY_BYTES)).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 50
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()

    var clients: List<Thread<int>> = []
    var k: int = 0
    for k < CLIENTS {
        clients.push(thread.spawn(fn() -> int { return client(port) }))
        k += 1
    }
    let coordinator: Thread<int> = thread.spawn(fn() -> int {
        return coordinate(control)
    })

    let stats: espresso.ServerStats = server.run().expect("run")
    for c: Thread<int> in clients {
        let code: int = c.join()
    }
    let cc: int = coordinator.join()
    io.println("exit")
}
