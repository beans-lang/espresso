package main

// The differential guard for the per-connection response-head cache. For every
// shape it frames the head two ways and requires the bytes to be equal:
//   - through ResponseHeadCache.frame_into (the cache path), and
//   - through std.http.encode_response_head_append with the same headers plus
//     Date (the plain path the server would otherwise take).
// The cache's bytes are std.http's own — the entry is built by calling
// encode_response_head_append — so equality is by construction; what this
// pins down is that the two spans the cache splices are located and written
// correctly. It sweeps status × reason × content-type × keep-alive × Server ×
// body length, with the lengths sitting on every Content-Length digit-width
// boundary (9/10, 99/100, 9999/10000, and 1 MiB) so a mis-sized splice shows,
// and it frames across a Date-second boundary so the in-place Date patch shows.
// A body-forbidden status must be declined, not cached. Only booleans and
// counts are printed, so the golden is deterministic.

import espresso
import std.http
import std.io

fn std_headers(content_type: string, server: string) -> http.Headers {
    let h: http.Headers = new http.Headers()
    h.add("Content-Type", content_type)
    if server != "" { h.add("Server", server) }
    return h
}

// The head the server's plain path produces: the same standard headers plus a
// Date, framed by std.http for this exact body length.
fn plain_head(status: int, reason: string, content_type: string,
              server: string, date: string, keep_alive: bool,
              body_len: int) -> Bytes {
    let h: http.Headers = std_headers(content_type, server)
    h.add("Date", date)
    let buf: Bytes = new Bytes(0)
    let forbidden: bool = http.encode_response_head_append(
        buf, status, reason, h, body_len, keep_alive).expect("encode")
    return move buf
}

fn frames_equal(cache: espresso.ResponseHeadCache,
                status: int, reason: string, content_type: string,
                server: string, date: string, second: int,
                keep_alive: bool, body_len: int) -> bool {
    let got: Bytes = new Bytes(0)
    let framed: bool = cache.frame_into(
        got, status, reason, content_type, std_headers(content_type, server),
        keep_alive, body_len, date, second).expect("frame")
    if !framed { return false }
    let want: Bytes = plain_head(
        status, reason, content_type, server, date, keep_alive, body_len)
    return got.to_string() == want.to_string()
}

fn main() {
    let d1: string = "Sun, 06 Nov 1994 08:49:37 GMT"
    let ctypes: List<string> = [
        "application/json; charset=utf-8", "text/plain; charset=utf-8"]
    let servers: List<string> = ["", "espresso"]
    let lengths: List<int> = [
        0, 9, 10, 99, 100, 9999, 10000, 16383, 16384, 1048575, 1048576]
    let statuses: List<int> = [200, 201, 404, 500]
    let reasons: List<string> = [
        "OK", "Created", "Not Found", "Internal Server Error"]

    var checks: int = 0
    var mismatches: int = 0
    // One cache per Server value, as in production: a connection's cache belongs
    // to one app, so Server is constant for it and stays out of the key. Within
    // a cache, a changed status/content-type/keep-alive rebuilds the entry and a
    // repeated key with a new length hits it and only re-splices the digits.
    for sv: int in 0..servers.len() {
        let cache: espresso.ResponseHeadCache =
            new espresso.ResponseHeadCache()
        for si: int in 0..statuses.len() {
            for ci: int in 0..ctypes.len() {
                for keep: int in 0..2 {
                    for li: int in 0..lengths.len() {
                        checks += 1
                        let ok: bool = frames_equal(
                            cache, statuses[si], reasons[si], ctypes[ci],
                            servers[sv], d1, 100, keep == 0, lengths[li])
                        if !ok { mismatches += 1 }
                    }
                }
            }
        }
    }

    // The Date patches in place across a second boundary: same key, new second
    // and new Date, must still equal the plain head with that Date.
    let d2: string = "Mon, 07 Nov 1994 08:49:38 GMT"
    let date_cache: espresso.ResponseHeadCache = new espresso.ResponseHeadCache()
    let p1: bool = frames_equal(
        date_cache, 200, "OK", "text/plain; charset=utf-8", "espresso",
        d1, 100, true, 42)
    let p2: bool = frames_equal(
        date_cache, 200, "OK", "text/plain; charset=utf-8", "espresso",
        d2, 101, true, 42)

    // A body-forbidden status is declined, never cached.
    let forbidden_buf: Bytes = new Bytes(0)
    let forbidden_framed: bool = date_cache.frame_into(
        forbidden_buf, 204, "No Content", "text/plain; charset=utf-8",
        std_headers("text/plain; charset=utf-8", ""), true, 0, d1, 100)
        .expect("frame")

    io.println("differential {checks} checks mismatches {mismatches}")
    io.println("date-patch first {p1} second {p2}")
    io.println("forbidden-declined {!forbidden_framed}")
}
