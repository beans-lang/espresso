package main

// The resident-memory gate for the BytesResult payload hand-off (results.b) —
// the bytes-path twin of tests/rss.b, which drives the string path only. That
// gap is why the last body copy of issue #5 sat in `BytesResult.execute`
// through a green suite: nothing measured the memory a bytes response costs.
//
// What it measures, and why the shape is what it is. The copy this gate is
// aimed at is `self.body.slice(0, self.body.len())`: a payload the application
// already owns, duplicated so it can be handed to the response. The duplicate
// is only visible in resident memory while BOTH copies are alive, so the
// program keeps both alive on purpose:
//
//   * the application owns CLIENTS payloads of 1 MiB, each parked in a
//     BytesResult built before the server starts — an outbound queue, one
//     prepared response per request it is about to answer;
//   * each of the CLIENTS connections takes one and is served it, then holds
//     the connection open without sending another request, so the response
//     that carries the payload is never reset.
//
// With the payload moved out of the result, those are the SAME megabyte in two
// places, and the process holds CLIENTS MiB. With the slice copy, the result
// still holds its megabyte and the response holds a second one, and the
// process holds twice that. rss_bytes_gate reads the peak while all 32 are
// live; the limit sits between the two.
//
// Native only: under the tree interpreter the process is the whole compiler
// and its baseline RSS dwarfs the thing under test.

import espresso
import std.io
import std.net
import std.thread
import std.time

const BODY_BYTES: int = 1048576   // 1 MiB
const CLIENTS: int = 32
const SCRATCH: int = 16384        // the client's whole receive footprint

// Process-wide coordination between the client threads, the coordinator, and
// the outside driver, plus the outbound queue the handler draws from. Atomics
// because these cells are touched from 33 threads.
singleton class BytesCoord {
    arrived: Atomic<int> = new Atomic<int>(0)
    failed: Atomic<int> = new Atomic<int>(0)
    release: Atomic<bool> = new Atomic<bool>(false)
    next: Atomic<int> = new Atomic<int>(0)

    fn arrive() { self.arrived.fetch_add(1, MemoryOrder.acq_rel) }
    fn fail() { self.failed.fetch_add(1, MemoryOrder.acq_rel) }
    fn arrived_now() -> int { return self.arrived.load(MemoryOrder.acquire) }
    fn failed_now() -> int { return self.failed.load(MemoryOrder.acquire) }
    fn total() -> int {
        return self.arrived.load(MemoryOrder.acquire) +
               self.failed.load(MemoryOrder.acquire)
    }
    // Hands out each queued response exactly once. A BytesResult answers one
    // request, so the index only ever moves forward.
    fn take_slot() -> int { return self.next.fetch_add(1, MemoryOrder.acq_rel) }
    fn release_all() { self.release.store(true, MemoryOrder.release) }
    fn wait_release() {
        for !self.release.load(MemoryOrder.acquire) {
            time.sleep_millis(2)
        }
    }
}

fn head_end_of(resp: Bytes) -> int {
    var i: int = 0
    let n: int = resp.len()
    for i + 4 <= n {
        if resp.get(i) == 13 && resp.get(i + 1) == 10 &&
           resp.get(i + 2) == 13 && resp.get(i + 3) == 10 {
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
            match stream.write_text("GET /queued HTTP/1.1\r\nHost: a\r\n\r\n") {
                ok(_) => {}
                err(error) => { BytesCoord.instance.fail(); return 1 }
            }
            let scratch: Bytes = Bytes.filled(SCRATCH, 0)
            var head: Bytes = new Bytes(0)
            var clen: int = -1
            var body_start: int = -1
            for body_start < 0 {
                match stream.read_into(scratch) {
                    ok(got) => {
                        if got == 0 { BytesCoord.instance.fail(); return 2 }
                        head.append_range(scratch, 0, got)
                        let he: int = head_end_of(head)
                        if he >= 0 {
                            body_start = he + 4
                            clen = clen_from(head.slice(0, he).to_string())
                        }
                    }
                    err(error) => { BytesCoord.instance.fail(); return 3 }
                }
            }
            if clen != BODY_BYTES { BytesCoord.instance.fail(); return 4 }
            var have: int = head.len() - body_start
            for have < clen {
                match stream.read_into(scratch) {
                    ok(got) => {
                        if got == 0 { BytesCoord.instance.fail(); return 5 }
                        have += got
                    }
                    err(error) => { BytesCoord.instance.fail(); return 6 }
                }
            }
            BytesCoord.instance.arrive()
            BytesCoord.instance.wait_release()
            let closed: Result<bool> = stream.close()
            return 0
        }
        err(error) => { BytesCoord.instance.fail(); return 7 }
    }
}

// Waits for all 32 to be holding, prints the marker the driver waits on, then
// blocks on stdin. When the driver has read RSS and answers, releases the
// connections and stops the server.
fn coordinate(control: espresso.ServerControl) -> int {
    for BytesCoord.instance.total() < CLIENTS {
        time.sleep_millis(5)
    }
    // stderr, because stdout is fully buffered when redirected to a file and a
    // stdout marker would not reach the driver until the process exits — which
    // is after the driver's input, a deadlock.
    io.eprintln("ready arrived {BytesCoord.instance.arrived_now()} failed {BytesCoord.instance.failed_now()}")
    let line: Option<string> = io.read_line()
    BytesCoord.instance.release_all()
    let stopped: Result<bool> = control.stop()
    return 0
}

// The outbound queue: one prepared BytesResult per request, each owning its own
// megabyte, all built before the server accepts anything so the application's
// share of the resident set is fixed and known.
fn map_queued(app: espresso.WebApplication,
              queue: List<espresso.BytesResult>) -> Result<bool> {
    return app.get(
        "/queued",
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            let slot: int = BytesCoord.instance.take_slot()
            if slot >= queue.len() {
                return err("the outbound queue ran dry", "queue")
            }
            return ok(queue[slot])
        })
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")

    var queue: List<espresso.BytesResult> = []
    var q: int = 0
    for q < CLIENTS {
        queue.push(new espresso.BytesResult(
            200, Bytes.filled(BODY_BYTES, 65 + (q % 26)),
            "application/octet-stream"))
        q += 1
    }
    map_queued(app, queue).expect("route")

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
