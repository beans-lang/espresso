package main

// The vectored large-body path (server.b: append_response / flush_with_body,
// http.encode_response_head_append). Bodies at or above vectored_body_min
// (16384) are framed head-first and sent beside the head with write_vectored,
// never copied into the output queue; a HEAD frames the head from the body's
// length and never touches the body. None of that was exercised by any test —
// the only HEAD drill was a 2-byte /hello and no test served a body over the
// threshold — so reverting flush_with_body broke nothing. This closes that.
//
// It hits a real socket (a TestHost never frames onto the wire), and prints
// only booleans and parsed lengths, so the golden stays deterministic while
// every byte of every body is compared exactly. It covers, on both engines:
//   * GET of a 1 MiB text body, a 247 KiB text body, a 1 MiB Bytes body,
//     a 16384-byte body (exactly the threshold) and a 16383-byte one (just
//     under, so the small append path), each with exact bytes and the
//     Content-Length and Connection: close framing;
//   * HEAD of each: the head carries the GET's Content-Length and no body;
//   * pipelined requests on one connection mixing a small and a large body in
//     both orders, split back out by Content-Length and required to arrive in
//     request order with exact bytes and nothing extra;
//   * a peer that reads in small chunks with sleeps between, forcing the
//     server's socket buffer to fill so write_vectored short-writes and
//     resumes from an offset that lands inside the body.

import espresso
import std.io
import std.net
import std.thread
import std.time

const K1M: int = 1048576      // 1 MiB, 1024 blocks
const K247: int = 252928      // 247 KiB, 247 blocks
const THR: int = 16384        // == server.b vectored_body_min (16 blocks)
const SUB: int = 16383        // one under the threshold: the small append path
const SMALL: int = 7          // a tiny body, always appended

// A deterministic body of length n. A 1024-byte block whose byte j is
// 33 + (j % 94) (printable ASCII) is appended to fill n, so building a
// megabyte is memcpy-bound rather than a million interpreter iterations.
// The body is compared in full byte for byte, so the only fact the pattern
// owes is that different positions usually hold different values — enough
// that any real reorder, duplication or truncation changes some byte.
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

// ---- response parsing on raw bytes ----------------------------------------

// Index of the first CRLF-CRLF, or -1. Walks bytes so a binary body cannot
// confuse it.
fn head_end(resp: Bytes) -> int {
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

// Connect, send one request, read until the peer closes. The single-response
// checks all send Connection: close, so read_to_end returning is itself the
// proof the socket closed.
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
    let clen_ok: bool = clen_of(head) == expected.len()
    let len_ok: bool = body.len() == expected.len()
    let bytes_ok: bool = body.to_string() == expected
    let close_ok: bool = head.contains("\r\nConnection: close\r\n")
    return "{path} GET status {status_ok} clen {clen_ok} len {len_ok} bytes {bytes_ok} close {close_ok}"
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

// Two pipelined responses on one connection, walked apart by Content-Length.
// `first` is keep-alive, `second` closes; requiring the second response to end
// exactly at the buffer's end proves nothing was duplicated or left behind.
fn check_pipe(port: int, label: string,
              first: string, first_exp: string,
              second: string, second_exp: string) -> string {
    let req: string =
        "GET {first} HTTP/1.1\r\nHost: a\r\n\r\nGET {second} HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n"
    let resp: Bytes = fetch_closing(port, req)
    let h1: int = head_end(resp)
    if h1 < 0 { return "{label} no-head-1" }
    let head1: string = resp.slice(0, h1).to_string()
    let clen1: int = clen_of(head1)
    let body1_start: int = h1 + 4
    let body1_end: int = body1_start + clen1
    if clen1 < 0 || body1_end > resp.len() { return "{label} short-1" }
    let body1: Bytes = resp.slice(body1_start, body1_end)
    let rest: Bytes = resp.slice(body1_end, resp.len())
    let h2: int = head_end(rest)
    if h2 < 0 { return "{label} no-head-2" }
    let head2: string = rest.slice(0, h2).to_string()
    let clen2: int = clen_of(head2)
    let body2_start: int = h2 + 4
    let body2_end: int = body2_start + clen2
    if clen2 < 0 || body2_end > rest.len() { return "{label} short-2" }
    let body2: Bytes = rest.slice(body2_start, body2_end)
    let ok1: bool = body1.to_string() == first_exp
    let ok2: bool = body2.to_string() == second_exp
    let exact: bool = body2_end == rest.len()
    return "{label} first {ok1} second {ok2} exact {exact}"
}

// A peer that reads 4 KiB at a time with a 1 ms pause between reads. The
// server's send buffer fills, so write_vectored short-writes and flush_with_body
// resumes from an offset that falls inside the body. The received bytes must
// still equal the golden; a runaway (an offset that forgot its progress and
// resent) trips the cap and fails on length.
fn check_slow(port: int, path: string, expected: string) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            let armed: Result<bool> = stream.set_timeouts(8000, 8000)
            match stream.write_text(get_request(path)) {
                ok(_) => {}
                err(error) => { return "{path} SLOW write-failed" }
            }
            let acc: Bytes = new Bytes(0)
            let cap: int = expected.len() + 65536
            var reading: bool = true
            for reading {
                match stream.read(4096) {
                    ok(chunk) => {
                        if chunk.len() == 0 {
                            reading = false
                        } else {
                            acc.append(chunk)
                            if acc.len() > cap { reading = false }
                            time.sleep_millis(1)
                        }
                    }
                    err(error) => { reading = false }
                }
            }
            let hend: int = head_end(acc)
            if hend < 0 { return "{path} SLOW no-head" }
            let body: Bytes = acc.slice(hend + 4, acc.len())
            let len_ok: bool = body.len() == expected.len()
            let bytes_ok: bool = body.to_string() == expected
            return "{path} SLOW len {len_ok} bytes {bytes_ok}"
        }
        err(error) => { return "{path} SLOW connect-failed" }
    }
}

fn client(port: int, control: espresso.ServerControl) -> string {
    let e1m: string = make_body(K1M)
    let e247: string = make_body(K247)
    let ethr: string = make_body(THR)
    let esub: string = make_body(SUB)
    let esm: string = make_body(SMALL)

    var lines: List<string> = []
    lines.push(check_get(port, "/text1m", e1m))
    lines.push(check_get(port, "/text247k", e247))
    lines.push(check_get(port, "/bytes1m", e1m))
    lines.push(check_get(port, "/thr", ethr))
    lines.push(check_get(port, "/sub", esub))
    lines.push(check_head(port, "/text1m", K1M))
    lines.push(check_head(port, "/text247k", K247))
    lines.push(check_head(port, "/bytes1m", K1M))
    lines.push(check_head(port, "/thr", THR))
    lines.push(check_head(port, "/sub", SUB))
    lines.push(check_pipe(port, "pipe large-small",
                          "/text1m", e1m, "/small", esm))
    lines.push(check_pipe(port, "pipe small-large",
                          "/small", esm, "/text1m", e1m))
    lines.push(check_slow(port, "/text1m", e1m))
    let stopped: bool = control.stop().or(false)
    lines.push("stopped {stopped}")
    return lines.join("\n")
}

// The closure captures the body string (a function parameter — the shape the
// checker accepts) so each request answers with the same bytes.
fn map_text(app: espresso.WebApplication,
            path: string, body: string) -> Result<bool> {
    return app.get(
        path,
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return espresso.text_status(200, body)
        })
}

fn map_bytes(app: espresso.WebApplication,
             path: string, body: string) -> Result<bool> {
    return app.get(
        path,
        fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
            return ok(new espresso.BytesResult(
                200, Bytes.from(body), "application/octet-stream"))
        })
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_text(app, "/text1m", make_body(K1M)).expect("route")
    map_text(app, "/text247k", make_body(K247)).expect("route")
    map_bytes(app, "/bytes1m", make_body(K1M)).expect("route")
    map_text(app, "/thr", make_body(THR)).expect("route")
    map_text(app, "/sub", make_body(SUB)).expect("route")
    map_text(app, "/small", make_body(SMALL)).expect("route")

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
