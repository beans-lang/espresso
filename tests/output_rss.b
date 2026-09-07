package main

// The resident-memory gate for the bounded output queue (server.b).
//
// Eight keep-alive connections each pipeline 200 requests in one burst, drain
// all 200 responses through a reused 16 KiB buffer, and then HOLD THE
// CONNECTION OPEN and park. output_rss_gate.sh waits for the "ready" marker,
// reads `ps -o rss=` while all eight are live and idle, checks it against a
// threshold, then writes a line to stdin to let this program let go and exit.
//
// Why it measures what it measures: one read carries the whole burst, so the
// server frames all 200 responses into that connection's output queue before it
// flushes. Each response is 15,000 bytes — just under vectored_body_min, so it
// is copied into the queue rather than sent beside its head — which made the
// queue grow to 3,026,000 bytes and, because resize(0) frees no pages, kept it
// for the life of the connection: eight connections retained ~24 MiB that no
// later request shrank. With the queue bounded by max_queued_output_bytes and
// released once it outgrows that bound, an idle connection holds a kilobyte,
// and the peak here is the process's baseline.
//
// The clients hold nothing: they drain through one 16 KiB scratch buffer and
// only count bytes, so the resident set being measured is the server's.
//
// Native only: under the tree interpreter the process is the whole compiler and
// its baseline RSS dwarfs the thing under test.

import espresso
import std.io
import std.net
import std.thread
import std.time

const BODY_BYTES: int = 15000     // under vectored_body_min: framed into the queue
const PIPELINE: int = 200         // requests written as one burst per connection
const CLIENTS: int = 8
const SCRATCH: int = 16384        // the client's whole receive footprint

// Process-wide coordination between the client threads, the coordinator, and
// the outside driver. Atomics because these cells are touched from 9 threads.
singleton class OutCoord {
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

// Pipeline PIPELINE requests in one write, drain every response byte, then hold
// the connection open until the driver releases it.
//
// Every response of this run has the same status, reason, content type and
// Content-Length, and an IMF-fixdate Date is a fixed 29 bytes, so every head is
// the same length: the first one gives the frame size and the rest is a byte
// count. A frame that did not repeat leaves the count short, the read times out
// and the connection is counted as failed — the driver refuses to measure a run
// with any failure, so a broken response can never pass this off as a small
// resident set.
fn client(port: int) -> int {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 5000) {
        ok(stream) => {
            let armed: Result<bool> = stream.set_timeouts(10000, 10000)
            let pipeline: Bytes = new Bytes(0)
            var sent: int = 0
            for sent < PIPELINE {
                pipeline.append_string("GET /chunk HTTP/1.1\r\nHost: a\r\n\r\n")
                sent += 1
            }
            match stream.write_all(pipeline) {
                ok(_) => {}
                err(error) => { OutCoord.instance.fail(); return 1 }
            }
            let scratch: Bytes = Bytes.filled(SCRATCH, 0)
            var head: Bytes = new Bytes(0)
            var frame: int = -1
            var have: int = 0
            for frame < 0 {
                match stream.read_into(scratch) {
                    ok(got) => {
                        if got == 0 { OutCoord.instance.fail(); return 2 }
                        have += got
                        head.append_range(scratch, 0, got)
                        let he: int = head_end_of(head)
                        if he >= 0 {
                            let clen: int =
                                clen_from(head.slice(0, he).to_string())
                            if clen != BODY_BYTES {
                                OutCoord.instance.fail(); return 3
                            }
                            frame = he + 4 + clen
                        }
                    }
                    err(error) => { OutCoord.instance.fail(); return 4 }
                }
            }
            // The head buffer has done its job; nothing below keeps a payload.
            head = new Bytes(0)
            let want: int = frame * PIPELINE
            for have < want {
                match stream.read_into(scratch) {
                    ok(got) => {
                        if got == 0 { OutCoord.instance.fail(); return 5 }
                        have += got
                    }
                    err(error) => { OutCoord.instance.fail(); return 6 }
                }
            }
            if have != want { OutCoord.instance.fail(); return 7 }
            OutCoord.instance.arrive()
            OutCoord.instance.wait_release()
            let closed: Result<bool> = stream.close()
            return 0
        }
        err(error) => { OutCoord.instance.fail(); return 8 }
    }
}

// Waits for all eight to be holding, prints the marker the driver waits on,
// then blocks on stdin. When the driver has read RSS and answers, releases the
// connections and stops the server.
fn coordinate(control: espresso.ServerControl) -> int {
    for OutCoord.instance.total() < CLIENTS {
        time.sleep_millis(5)
    }
    // The marker goes to stderr: stdout is fully buffered when redirected to a
    // file, so a stdout marker would not reach the driver until the process
    // exits — which is after the driver's input, a deadlock.
    io.eprintln("ready arrived {OutCoord.instance.arrived_now()} failed {OutCoord.instance.failed_now()}")
    let line: Option<string> = io.read_line()
    OutCoord.instance.release_all()
    let stopped: Result<bool> = control.stop()
    return 0
}

fn map_chunk(app: espresso.WebApplication, body: string) -> Result<bool> {
    return app.get(
        "/chunk",
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return espresso.text_status(200, body)
        })
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_chunk(app, make_body(BODY_BYTES)).expect("route")

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
    io.println("requests {stats.requests} responses {stats.responses} peak {stats.output_queue_peak} released {stats.output_buffers_released}")
}
