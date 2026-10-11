package main

// A connection's output queue is bounded, and a queue that outgrew its bound is
// released instead of kept for the connection's life.
//
// One read can carry hundreds of pipelined requests, and every response in that
// batch is framed into ServerConnection.output before the read loop flushes.
// Without a bound the queue grows to the whole batch and `resize(0)` frees no
// pages, so a client turns a few kilobytes of pipelined requests into megabytes
// of per-connection buffer that a later one-byte response does not shrink.
//
// Each case drives real sockets: one keep-alive connection, `count` pipelined
// GETs written in a single burst, and every response read back and checked —
// its body carries the six-digit index of the request that asked for it, so a
// dropped or reordered response fails the case, not just a memory number.
//
//   under-*  the shipped 64 KiB bound with a batch that stays under it. Nothing
//            is flushed mid-batch and nothing is released: the buffer reuse
//            that makes small pipelined responses cheap must survive the fix.
//   over-*   a 512-byte bound, so ONE response already crosses it. The counts
//            are then exactly `count`, whichever way the kernel splits the
//            burst across reads, and the queue never holds two responses.
//   issue-*  the shape from the report: the shipped bound and 200 pipelined
//            15,000-byte bodies (just under vectored_body_min, so they land in
//            the queue). Before the fix the queue peaked at the whole 3 MB
//            batch; now the peak is the bound plus the one response that
//            crossed it, and buffers come back.
//
// n=1, n=2 and n=many appear on both sides of the bound: a batch of one is the
// degenerate case, and a rule that only holds for the big shape proves nothing.

import espresso
import std.io
import std.net
import std.thread

// Six digits of request index lead every body, and the filler unit is six bytes
// too, so any body length divisible by six is exact.
const MARK: int = 6
const SMALL_BODY: int = 1002       // one response ~1.1 KB, framed into the queue
const BIG_BODY: int = 15000        // still under vectored_body_min (16384)
const SMALL_BOUND: int = 512       // below one response: every response flushes
const DEFAULT_BOUND: int = 65536   // ServerOptions.max_queued_output_bytes

fn pad_mark(value: int) -> string {
    var text: string = "{value}"
    for text.len() < MARK { text = "0{text}" }
    return text
}

fn body_for(mark: string, total: int) -> string {
    return "{mark}{"abcdef".repeat((total - MARK) / MARK)}"
}

fn small(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let id: string = context.request.route("id").or("??????")
    return espresso.text_status(200, body_for(id, SMALL_BODY))
}

fn big(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let id: string = context.request.route("id").or("??????")
    return espresso.text_status(200, body_for(id, BIG_BODY))
}

// The offset of the CRLFCRLF that ends a response head, at or after `from`.
fn find_head_end(raw: Bytes, from: int) -> int {
    var at: int = if from < 0 { 0 } else { from }
    for at + 4 <= raw.len() {
        if raw.get_u8(at) == 13 && raw.get_u8(at + 1) == 10 &&
           raw.get_u8(at + 2) == 13 && raw.get_u8(at + 3) == 10 {
            return at
        }
        at += 1
    }
    return -1
}

fn marked(raw: Bytes, at: int, mark: string) -> bool {
    var index: int = 0
    for index < mark.len() {
        if raw.get_u8(at + index) != mark.byte_at(index) { return false }
        index += 1
    }
    return true
}

// What one case's client saw, and what the server counted while it served it.
// It is built on the main thread from the client's line and the run's stats —
// a class is not Send, so it never crosses into the client fiber.
class CaseResult {
    label: string = ""
    outcome: string = ""
    flushes: int = 0
    released: int = 0
    peak: int = 0

    fn init() {}
}

// Pipelines `count` GETs down one keep-alive connection in a single write, then
// reads every response back in order. A response is complete when its head has
// arrived and `body_len` bytes follow; its first six body bytes must be the
// index of the request that asked for it.
fn burst(port: int, path: string, count: int, body_len: int) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            let armed: Result<bool> = stream.set_timeouts(8000, 8000)
            let pipeline: Bytes = new Bytes(0)
            var index: int = 0
            for index < count {
                pipeline.append_string(
                    "GET {path}/{pad_mark(index)} HTTP/1.1\r\nHost: a\r\n\r\n")
                index += 1
            }
            match stream.write_all(pipeline) {
                ok(_) => {}
                err(problem) => { return "write-failed" }
            }
            let seen: Bytes = new Bytes(0)
            var at: int = 0
            var done: int = 0
            var ordered: bool = true
            for done < count {
                var grew: bool = false
                match stream.read(65536) {
                    ok(part) => {
                        if part.len() > 0 {
                            seen.append(part)
                            grew = true
                        }
                    }
                    err(problem) => {}
                }
                if !grew { break }
                for done < count {
                    let head_end: int = find_head_end(seen, at)
                    if head_end < 0 { break }
                    let body_at: int = head_end + 4
                    if body_at + body_len > seen.len() { break }
                    if !marked(seen, body_at, pad_mark(done)) {
                        ordered = false
                    }
                    at = body_at + body_len
                    done += 1
                }
            }
            let closed: Result<bool> = stream.close()
            return "responses {done} ordered {ordered}"
        }
        err(problem) => {}
    }
    return "connect-failed"
}

// One server, one connection, one burst. Each case gets its own run so its
// ServerStats counts only its own traffic.
fn run_case(label: string, path: string, count: int, body_len: int,
            bound: int) -> CaseResult {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get(r"/s/{id}", small).expect("route s")
    app.get(r"/b/{id}", big).expect("route b")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    options.max_queued_output_bytes = bound
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        let line: string = burst(port, path, count, body_len)
        let stopped: bool = control.stop().or(false)
        return line
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    let result: CaseResult = new CaseResult()
    result.label = label
    result.outcome = visitor.join()
    result.flushes = stats.output_queue_flushes
    result.released = stats.output_buffers_released
    result.peak = stats.output_queue_peak
    return result
}

fn main() {
    // Under the shipped bound: a batch that never reaches it must not be
    // flushed mid-batch and must not hand its buffer back — that reuse is what
    // makes small pipelined responses cheap. 40 * ~1.1 KB is still under 64 KiB,
    // so this holds however the kernel splits the burst.
    for count: int in [1, 2, 40] {
        let done: CaseResult = run_case(
            "under-{count}", "/s", count, SMALL_BODY, DEFAULT_BOUND)
        io.println(
            "{done.label} {done.outcome} flushes {done.flushes} released {done.released}")
    }

    // Past the bound: with 512 bytes allowed, every single response crosses it,
    // so the queue is pushed and released once per response no matter how the
    // burst is split across reads, and it never holds two responses at once.
    for count: int in [1, 2, 40] {
        let done: CaseResult = run_case(
            "over-{count}", "/s", count, SMALL_BODY, SMALL_BOUND)
        io.println(
            "{done.label} {done.outcome} flushes {done.flushes} released {done.released} one_response {done.peak < 2 * SMALL_BODY}")
    }

    // The reported shape, at the shipped default. The peak is an invariant of
    // the bound — it cannot exceed the bound plus the one response that crossed
    // it, whatever the batching — and 3 MB of responses cross a 64 KiB bound
    // dozens of times under any split the kernel could produce of a single
    // 4.4 KB write. Before the fix this peaked at 3,026,000 and released
    // nothing.
    let issue: CaseResult = run_case(
        "issue-200", "/b", 200, BIG_BODY, DEFAULT_BOUND)
    io.println(
        "{issue.label} {issue.outcome} peak_bounded {issue.peak <= DEFAULT_BOUND + BIG_BODY + 1024} released_positive {issue.released > 0}")
}
