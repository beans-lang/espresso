package main

// BytesResult hands its payload to the response instead of copying it — the
// last body copy of issue #5. `execute` called
// `self.body.slice(0, self.body.len())`, a full duplicate of the payload on
// every response; it now lifts the payload out of a one-slot field with
// List.remove, the consuming accessor the language names for a field that
// `move` cannot reach.
//
// Handing the payload over rather than copying it makes a BytesResult
// single-use, so this pins both halves against a real socket, on both engines:
//
//   * GET of a BytesResult body at 0, 1 and 7 bytes, at 16383 (one under the
//     server's vectored threshold, so the append path), at 16384 (exactly the
//     threshold, so the vectored path) and at 1 MiB — status, Content-Length
//     and every body byte;
//   * a 512-byte payload holding all 256 byte values twice, compared byte for
//     byte, so no text-shaped round trip of the body could hide in a golden
//     that only ever saw printable ASCII;
//   * HEAD of each: the head carries the GET's Content-Length and no body,
//     framed without the payload;
//   * a BytesResult cached across requests — the shape a user reaches for to
//     serve a fixed asset. The first request answers 200 with the payload; the
//     SECOND is refused with the error naming the mistake. That is the case
//     that must never become "200 with an empty body", which is what a
//     moved-out payload sends if nobody checks.
//
// n=1 proves nothing here, so the sizes straddle the vectored threshold on
// both sides and include the empty body and the single byte. Reverting
// BytesResult to the slice copy turns the ONCE line's `second 500` into
// `second 200` and the golden goes red.

import espresso
import std.io
import std.net
import std.thread

const THR: int = 16384        // == server.b vectored_body_min
const SUB: int = 16383        // one under it: the small append path
const BIG: int = 1048576      // 1 MiB
const SMALL: int = 7
const BIN: int = 512          // every byte value, twice

// A deterministic printable body of length n, built from a 1024-byte block so
// a megabyte is memcpy-bound rather than a million interpreter iterations.
fn make_body(n: int) -> string {
    let block: Bytes = new Bytes(0)
    block.reserve(1024)
    var i: int = 0
    for i < 1024 {
        block.push(33 + (i % 94))
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
        out.push(33 + ((done % 1024) % 94))
        done += 1
    }
    return out.to_string()
}

// n bytes cycling through every value 0..255, NUL and the high half included.
// Never routed through a string on either side.
fn make_binary(n: int) -> Bytes {
    let out: Bytes = new Bytes(0)
    out.reserve(n)
    var i: int = 0
    for i < n {
        out.push(i % 256)
        i += 1
    }
    return move out
}

fn bytes_equal(left: Bytes, right: Bytes) -> bool {
    if left.len() != right.len() { return false }
    var i: int = 0
    for i < left.len() {
        if left.get(i) != right.get(i) { return false }
        i += 1
    }
    return true
}

// ---- response parsing on raw bytes ----------------------------------------

// Index of the first CRLF-CRLF, or -1. Walks bytes so a binary body cannot
// confuse it.
fn head_end(resp: Bytes) -> int {
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

// The Content-Length value in a header block, or -1.
fn clen_of(head: string) -> int {
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

fn fetch_closing(port: int, req: string) -> Bytes {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            let armed: Result<bool> = stream.set_timeouts(8000, 8000)
            match stream.write_text(req) {
                ok(_) => {}
                err(error) => { return Bytes.from("write-failed-{error.kind}") }
            }
            return stream.read_to_end(4194304).or(new Bytes(0))
        }
        err(error) => { return Bytes.from("connect-failed-{error.kind}") }
    }
}

fn get_request(path: string) -> string {
    return "GET {path} HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
}

fn check_get(port: int, path: string, expected: string) -> string {
    let resp: Bytes = fetch_closing(port, get_request(path))
    let hend: int = head_end(resp)
    if hend < 0 { return "{path} GET no-head" }
    let head: string = resp.slice(0, hend).to_string()
    let body: Bytes = resp.slice(hend + 4, resp.len())
    let status_ok: bool = head.starts_with("HTTP/1.1 200 OK")
    let type_ok: bool =
        head.contains("\r\nContent-Type: application/octet-stream\r\n")
    let clen_ok: bool = clen_of(head) == expected.len()
    let len_ok: bool = body.len() == expected.len()
    let bytes_ok: bool = body.to_string() == expected
    return "{path} GET status {status_ok} type {type_ok} clen {clen_ok} len {len_ok} bytes {bytes_ok}"
}

// The binary payload's twin: compared byte for byte, never through a string.
fn check_get_binary(port: int, path: string, expected: Bytes) -> string {
    let resp: Bytes = fetch_closing(port, get_request(path))
    let hend: int = head_end(resp)
    if hend < 0 { return "{path} GET no-head" }
    let head: string = resp.slice(0, hend).to_string()
    let body: Bytes = resp.slice(hend + 4, resp.len())
    let status_ok: bool = head.starts_with("HTTP/1.1 200 OK")
    let clen_ok: bool = clen_of(head) == expected.len()
    let bytes_ok: bool = bytes_equal(body, expected)
    return "{path} GET status {status_ok} clen {clen_ok} bytes {bytes_ok}"
}

fn check_head(port: int, path: string, expected_len: int) -> string {
    let req: string = "HEAD {path} HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
    let resp: Bytes = fetch_closing(port, req)
    let hend: int = head_end(resp)
    if hend < 0 { return "{path} HEAD no-head" }
    let head: string = resp.slice(0, hend).to_string()
    let status_ok: bool = head.starts_with("HTTP/1.1 200 OK")
    let clen_ok: bool = clen_of(head) == expected_len
    // Nothing after the blank line: the head is the whole message.
    let bodyless: bool = resp.len() == hend + 4
    return "{path} HEAD status {status_ok} clen {clen_ok} bodyless {bodyless}"
}

// One BytesResult, two requests. The payload leaves the result on the first
// one, so the second must be refused by name — never answered 200 with an
// empty body. detailed_errors is on, so the refusal's own words reach the
// client and this pins the message, not just the status.
fn check_once(port: int, path: string, expected: string) -> string {
    let first: Bytes = fetch_closing(port, get_request(path))
    let h1: int = head_end(first)
    if h1 < 0 { return "{path} ONCE no-head-1" }
    let head1: string = first.slice(0, h1).to_string()
    let body1: Bytes = first.slice(h1 + 4, first.len())
    let first_ok: bool = head1.starts_with("HTTP/1.1 200 OK") &&
                         body1.to_string() == expected

    let second: Bytes = fetch_closing(port, get_request(path))
    let h2: int = head_end(second)
    if h2 < 0 { return "{path} ONCE no-head-2" }
    let head2: string = second.slice(0, h2).to_string()
    let body2: string = second.slice(h2 + 4, second.len()).to_string()
    let refused: bool =
        head2.starts_with("HTTP/1.1 500 Internal Server Error")
    let named: bool = body2.contains("already handed its body to a response")
    // The failure mode this whole line exists to catch: a second 200 whose
    // body is empty, which is what a moved-out payload sends unguarded.
    let not_empty_200: bool =
        !(head2.starts_with("HTTP/1.1 200") && body2 == "")
    return "{path} ONCE first {first_ok} second {refused} named {named} not-empty-200 {not_empty_200}"
}

fn client(port: int, control: espresso.ServerControl) -> string {
    let e0: string = make_body(0)
    let e1: string = make_body(1)
    let esm: string = make_body(SMALL)
    let esub: string = make_body(SUB)
    let ethr: string = make_body(THR)
    let ebig: string = make_body(BIG)

    var lines: List<string> = []
    lines.push(check_get(port, "/b0", e0))
    lines.push(check_get(port, "/b1", e1))
    lines.push(check_get(port, "/b7", esm))
    lines.push(check_get(port, "/b16383", esub))
    lines.push(check_get(port, "/b16384", ethr))
    lines.push(check_get(port, "/b1m", ebig))
    lines.push(check_get_binary(port, "/bin", make_binary(BIN)))
    lines.push(check_head(port, "/b0", 0))
    lines.push(check_head(port, "/b1", 1))
    lines.push(check_head(port, "/b7", SMALL))
    lines.push(check_head(port, "/b16383", SUB))
    lines.push(check_head(port, "/b16384", THR))
    lines.push(check_head(port, "/b1m", BIG))
    lines.push(check_head(port, "/bin", BIN))
    lines.push(check_once(port, "/once", esm))
    let stopped: bool = control.stop().or(false)
    lines.push("stopped {stopped}")
    return lines.join("\n")
}

// A fresh BytesResult per request, the shape a handler that produces bytes
// writes. The closure captures the body string (a function parameter — the
// shape the checker accepts) and turns it into the request's own payload.
fn map_bytes(app: espresso.WebApplication,
             path: string, body: string) -> Result<bool> {
    return app.get(
        path,
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return ok(new espresso.BytesResult(
                200, Bytes.from(body), "application/octet-stream"))
        })
}

fn map_binary(app: espresso.WebApplication,
              path: string, n: int) -> Result<bool> {
    return app.get(
        path,
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return ok(new espresso.BytesResult(
                200, make_binary(n), "application/octet-stream"))
        })
}

// One BytesResult built at startup and returned by every request — a cached
// asset, and the program the one-shot contract is aimed at.
fn map_once(app: espresso.WebApplication,
            path: string, body: string) -> Result<bool> {
    let cached: espresso.BytesResult = new espresso.BytesResult(
        200, Bytes.from(body), "application/octet-stream")
    return app.get(
        path,
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return ok(cached)
        })
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    // The refusal's own words must reach the client for check_once to pin
    // them; in production the same failure is the generic 500 plus a record.
    builder.options.detailed_errors = true
    let app: espresso.WebApplication = builder.build().expect("app")
    map_bytes(app, "/b0", make_body(0)).expect("route")
    map_bytes(app, "/b1", make_body(1)).expect("route")
    map_bytes(app, "/b7", make_body(SMALL)).expect("route")
    map_bytes(app, "/b16383", make_body(SUB)).expect("route")
    map_bytes(app, "/b16384", make_body(THR)).expect("route")
    map_bytes(app, "/b1m", make_body(BIG)).expect("route")
    map_binary(app, "/bin", BIN).expect("route")
    map_once(app, "/once", make_body(SMALL)).expect("route")

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
}
