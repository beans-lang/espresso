// Streamed responses: the head goes out before the body exists, the body is
// framed as chunks, and however the same payload is split into chunks the
// client decodes the same bytes.
package main

import espresso
import std.http
import std.io
import std.net
import std.thread

// The payload every split case sends, in 64 bytes with no repeats, so a
// decoder that drops or reorders a piece cannot come out right by luck.
fn payload() -> string {
    return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"
}

// ---- the routes -------------------------------------------------------------

// Writes the payload in two chunks split at ?at=k. k=0 and k=len are the
// degenerate ends, where one of the two writes is empty and must vanish
// rather than terminate the body.
fn two_way(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    let at: int = context.request.query()?.get("at").or("0").to_int().or(0)
    let whole: string = payload()
    let out: espresso.ResponseStream =
        context.begin_stream(200, "text/plain; charset=utf-8")?
    out.write_text(whole.slice(0, at))?
    out.write_text(whole.slice(at, whole.len()))?
    out.finish()?
    return espresso.detached()
}

// Writes the payload in ?n= chunks of as equal a size as divides.
fn n_way(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let pieces: int = context.request.query()?.get("n").or("1").to_int().or(1)
    let whole: string = payload()
    let out: espresso.ResponseStream =
        context.begin_stream(200, "text/plain; charset=utf-8")?
    var start: int = 0
    for index: int in 0..pieces {
        var end: int = whole.len() * (index + 1) / pieces
        if index == pieces - 1 { end = whole.len() }
        out.write_text(whole.slice(start, end))?
        start = end
    }
    out.finish()?
    return espresso.detached()
}

// A chunk larger than one read buffer, sent as Bytes rather than a string, so
// the vectored path and the bytes path are both on the wire.
fn big(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let block: Bytes = new Bytes(0)
    block.reserve(200000)
    for index: int in 0..200000 { block.push(97 + index % 26) }
    let out: espresso.ResponseStream =
        context.begin_stream(200, "application/octet-stream")?
    out.write(block)?
    out.write_text("|tail")?
    out.finish()?
    return espresso.detached()
}

// Returns without finishing. The connection must terminate the body.
fn unfinished(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    let out: espresso.ResponseStream =
        context.begin_stream(200, "text/plain; charset=utf-8")?
    out.write_text("half")?
    return espresso.detached()
}

// Fails after the head is on the wire. There is no status left to send, so
// the body must be left unterminated and the connection closed.
fn broken(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let out: espresso.ResponseStream =
        context.begin_stream(200, "text/plain; charset=utf-8")?
    out.write_text("before")?
    return err("the handler gave up mid-stream", "stream_test")
}

// Adds its own headers before the head goes out, and asks for a status.
fn decorated(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    context.response.header("X-Espresso-Test", "yes")
    context.response.header("Cache-Control", "no-store")
    let out: espresso.ResponseStream =
        context.begin_stream(201, "text/plain; charset=utf-8")?
    out.write_text("made")?
    out.finish()?
    return espresso.detached()
}

// Every refusal begin_stream owns.
fn refusals(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    var lines: List<string> = []
    match context.begin_stream(204, "text/plain") {
        ok(_) => { lines.push("204 accepted (wrong)") }
        err(problem) => { lines.push("204 {problem.kind}") }
    }
    match context.begin_stream(304, "text/plain") {
        ok(_) => { lines.push("304 accepted (wrong)") }
        err(problem) => { lines.push("304 {problem.kind}") }
    }
    context.response.header("Content-Length", "5")
    match context.begin_stream(200, "text/plain") {
        ok(_) => { lines.push("content-length accepted (wrong)") }
        err(problem) => { lines.push("content-length {problem.kind}") }
    }
    context.response.headers.clear()
    let out: espresso.ResponseStream =
        context.begin_stream(200, "text/plain; charset=utf-8")?
    match context.begin_stream(200, "text/plain") {
        ok(_) => { lines.push("second accepted (wrong)") }
        err(problem) => { lines.push("second {problem.kind}") }
    }
    out.write_text(lines.join(" | "))?
    // An empty write is not a terminator.
    out.write_text("")?
    out.write(new Bytes(0))?
    out.write_text(" [chunks {out.chunk_count()} bytes {out.byte_count()}]")?
    out.finish()?
    match out.write_text("after") {
        ok(_) => { io.println("write after finish accepted (wrong)") }
        err(problem) => { io.println("write-after-finish {problem.kind}") }
    }
    io.println("finish twice {out.finish().is_ok()} finished {out.is_finished()}")
    return espresso.detached()
}

fn deferred_then_stream(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    let responder: espresso.Responder = context.respond_later()?
    match context.begin_stream(200, "text/plain") {
        ok(_) => { io.println("stream after respond_later accepted (wrong)") }
        err(problem) => {
            io.println("stream-after-defer {problem.kind}")
        }
    }
    responder.text(200, "OK", "answered by the responder")?
    return espresso.detached()
}

fn buffered(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("buffered-body")
}

// ---- the client -------------------------------------------------------------

class Peer {
    stream: net.TcpStream
    pending: Bytes = new Bytes(0)

    fn init(move stream: net.TcpStream) { self.stream = move stream }

    fn fill() -> bool {
        match self.stream.read(65536) {
            ok(chunk) => {
                if chunk.len() == 0 { return false }
                self.pending.append(chunk)
                return true
            }
            err(problem) => { return false }
        }
    }

    fn drop_front(count: int) {
        self.pending = self.pending.slice(count, self.pending.len())
    }

    fn send(text: string) -> bool {
        return self.stream.write_text(text).is_ok()
    }

    fn head() -> string {
        var rounds: int = 0
        for rounds < 4096 {
            rounds += 1
            match self.pending.to_string().find("\r\n\r\n") {
                some(at) => {
                    let head: string =
                        self.pending.slice(0, at + 4).to_string()
                    self.drop_front(at + 4)
                    return head
                }
                none => {}
            }
            if !self.fill() { break }
        }
        return ""
    }

    // Reads a chunked body and returns the decoded bytes, or a word saying
    // where the framing went wrong. `<truncated>` is a body the server left
    // unterminated, which is the deliberate answer to a handler that failed
    // after its head went out.
    fn chunked_body() -> string {
        let out: Bytes = new Bytes(0)
        var rounds: int = 0
        for rounds < 100000 {
            rounds += 1
            var text: string = self.pending.to_string()
            var line_end: int = -1
            match text.find("\r\n") {
                some(at) => { line_end = at }
                none => {}
            }
            if line_end < 0 {
                if !self.fill() { return "<truncated>" }
                continue
            }
            let size_line: string = text.slice(0, line_end)
            var size: int = 0
            var ok_hex: bool = size_line.len() > 0
            for index: int in 0..size_line.len() {
                let byte: int = size_line.byte_at(index)
                var digit: int = -1
                if byte >= 48 && byte <= 57 { digit = byte - 48 }
                if byte >= 97 && byte <= 102 { digit = byte - 87 }
                if byte >= 65 && byte <= 70 { digit = byte - 55 }
                if digit < 0 { ok_hex = false }
                else { size = size * 16 + digit }
            }
            if !ok_hex { return "<bad size line '{size_line}'>" }
            let need: int = line_end + 2 + size + 2
            for self.pending.len() < need {
                if !self.fill() { return "<truncated>" }
            }
            if size == 0 {
                self.drop_front(line_end + 4)
                return out.to_string()
            }
            out.append(self.pending.slice(line_end + 2, line_end + 2 + size))
            self.drop_front(need)
        }
        return "<runaway>"
    }

    fn close() -> bool { return self.stream.close().is_ok() }
}

fn dial(port: int) -> Result<Peer> {
    let stream: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 5000)?
    stream.set_timeouts(5000, 5000)?
    return ok(new Peer(move stream))
}

fn status_line(head: string) -> string {
    if head == "" { return "<closed with no answer>" }
    match head.find("\r\n") {
        some(at) => { return head.slice(0, at) }
        none => { return head }
    }
}

fn get(peer: Peer, target: string) -> bool {
    return peer.send("GET {target} HTTP/1.1\r\nHost: h\r\n\r\n")
}

// ---- the scenarios ----------------------------------------------------------

fn client(port: int, control: espresso.ServerControl) -> string {
    var lines: List<string> = []
    let whole: string = payload()

    // Every two-way split of the same payload, on one keep-alive connection,
    // must decode to the same bytes — including the two ends, where one of
    // the two writes is empty and must not be mistaken for a terminator.
    match dial(port) {
        err(problem) => { lines.push("split dial {problem.kind}") }
        ok(peer) => {
            var wrong: int = 0
            var statuses: int = 0
            for at: int in 0..whole.len() + 1 {
                if !get(peer, "/two?at={at}") { wrong += 1000 }
                if status_line(peer.head()) == "HTTP/1.1 200 OK" {
                    statuses += 1
                }
                if peer.chunked_body() != whole { wrong += 1 }
            }
            lines.push("two-way splits {whole.len() + 1} ok-status {statuses} wrong {wrong}")
            let closed: bool = peer.close()
        }
    }

    // The same payload cut into 1..16 chunks.
    match dial(port) {
        err(problem) => { lines.push("nway dial {problem.kind}") }
        ok(peer) => {
            var wrong: int = 0
            var sizes: List<string> = []
            for n: int in 1..17 {
                if !get(peer, "/n?n={n}") { wrong += 1000 }
                let head: string = peer.head()
                if !head.contains("Transfer-Encoding: chunked") {
                    wrong += 100
                }
                if head.contains("Content-Length") { wrong += 10 }
                if peer.chunked_body() != whole { wrong += 1 }
            }
            lines.push("n-way splits 16 wrong {wrong}")
            let closed: bool = peer.close()
        }
    }

    // A chunk bigger than a read buffer, then a small one after it.
    match dial(port) {
        err(problem) => { lines.push("big dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = get(peer, "/big")
            let head: string = status_line(peer.head())
            let body: string = peer.chunked_body()
            var shape: string = "len {body.len()}"
            if body.len() == 200005 {
                shape = "{shape} head {body.slice(0, 3)} tail {body.slice(200000, 200005)}"
            }
            lines.push("big {head} {shape}")
            let closed: bool = peer.close()
        }
    }

    // Handler-supplied headers, a non-200 status, and the framework headers.
    match dial(port) {
        err(problem) => { lines.push("decorated dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = get(peer, "/decorated")
            let head: string = peer.head()
            let body: string = peer.chunked_body()
            lines.push("decorated {status_line(head)} custom {head.contains("X-Espresso-Test: yes")} cache {head.contains("Cache-Control: no-store")} type {head.contains("Content-Type: text/plain; charset=utf-8")} date {head.contains("Date: ")} server {head.contains("Server: espresso-stream")} body [{body}]")
            let closed: bool = peer.close()
        }
    }

    // A handler that returned without finishing: the connection terminates
    // the body, and the connection stays usable.
    match dial(port) {
        err(problem) => { lines.push("unfinished dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = get(peer, "/unfinished")
            let head: string = status_line(peer.head())
            let body: string = peer.chunked_body()
            let again: bool = get(peer, "/buffered")
            let second: string = status_line(peer.head())
            lines.push("unfinished {head} [{body}] then {second}")
            let closed: bool = peer.close()
        }
    }

    // A handler that failed after its head went out.
    match dial(port) {
        err(problem) => { lines.push("broken dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = get(peer, "/broken")
            let head: string = status_line(peer.head())
            let body: string = peer.chunked_body()
            let after: bool = get(peer, "/buffered")
            let second: string = status_line(peer.head())
            lines.push("broken {head} [{body}] then [{second}]")
            let closed: bool = peer.close()
        }
    }

    // HEAD on a streaming route: the head of the GET response, no body.
    match dial(port) {
        err(problem) => { lines.push("head dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = peer.send(
                "HEAD /n?n=4 HTTP/1.1\r\nHost: h\r\n\r\nGET /buffered HTTP/1.1\r\nHost: h\r\n\r\n")
            let head: string = peer.head()
            // A HEAD response carries no body at all, so what follows the
            // blank line is the next response's head — which is the proof.
            let next_head: string = peer.head()
            for peer.pending.len() < 13 {
                if !peer.fill() { break }
            }
            let body: string = peer.pending.slice(0, 13).to_string()
            lines.push("head-request {status_line(head)} chunked {head.contains("Transfer-Encoding: chunked")} then {status_line(next_head)} [{body}]")
            let closed: bool = peer.close()
        }
    }

    // A buffered response pipelined in front of a streamed one: the buffered
    // answer is queued when the stream's head is framed, and must go first.
    match dial(port) {
        err(problem) => { lines.push("pipelined dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = peer.send(
                "GET /buffered HTTP/1.1\r\nHost: h\r\n\r\nGET /n?n=3 HTTP/1.1\r\nHost: h\r\n\r\n")
            let first: string = peer.head()
            for peer.pending.len() < 13 {
                if !peer.fill() { break }
            }
            // Guarded, so a regression that puts the streamed head in front
            // of this response reports it instead of panicking here.
            var first_body: string = "<missing>"
            if peer.pending.len() >= 13 {
                first_body = peer.pending.slice(0, 13).to_string()
                peer.drop_front(13)
            }
            let second: string = peer.head()
            let streamed: string = peer.chunked_body()
            lines.push("pipelined {status_line(first)} [{first_body}] then {status_line(second)} same-body {streamed == whole}")
            let closed: bool = peer.close()
        }
    }

    // Connection: close on the request puts it in the streamed head too.
    match dial(port) {
        err(problem) => { lines.push("close dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = peer.send(
                "GET /n?n=2 HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
            let head: string = peer.head()
            let body: string = peer.chunked_body()
            lines.push("close-request {status_line(head)} closes {head.contains("Connection: close")} body-ok {body == whole}")
            let closed: bool = peer.close()
        }
    }

    // The refusals, reported in the streamed body itself.
    match dial(port) {
        err(problem) => { lines.push("refusals dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = get(peer, "/refusals")
            let head: string = status_line(peer.head())
            lines.push("refusals {head} [{peer.chunked_body()}]")
            let closed: bool = peer.close()
        }
    }

    // respond_later then begin_stream.
    match dial(port) {
        err(problem) => { lines.push("defer dial {problem.kind}") }
        ok(peer) => {
            let asked: bool = get(peer, "/defer")
            let head: string = status_line(peer.head())
            lines.push("defer {head}")
            let closed: bool = peer.close()
        }
    }

    let stopped: bool = control.stop().or(false)
    return lines.join("\n")
}

fn main() {
    // A TestHost request never reaches a socket, so begin_stream must refuse
    // there and say which loop it needs.
    let offline_builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let offline: espresso.WebApplication =
        offline_builder.build().expect("offline app")
    offline.get("/s", fn(context: espresso.HttpContext) ->
        Result<espresso.ActionResult> {
        match context.begin_stream(200, "text/plain") {
            ok(_) => { return espresso.text("streamed (wrong)") }
            err(problem) => {
                return espresso.text("{problem.kind}: {problem.msg}")
            }
        }
    }).expect("s")
    let host: espresso.TestHost = new espresso.TestHost(offline)
    io.println("testhost {host.get("/s").expect("s").text()}")
    host.close().expect("close")

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.options.server_header = "espresso-stream"
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/two", two_way).expect("two")
    app.get("/n", n_way).expect("n")
    app.get("/big", big).expect("big")
    app.get("/unfinished", unfinished).expect("unfinished")
    app.get("/broken", broken).expect("broken")
    app.get("/decorated", decorated).expect("decorated")
    app.get("/refusals", refusals).expect("refusals")
    app.get("/defer", deferred_then_stream).expect("defer")
    app.get("/buffered", buffered).expect("buffered")

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
    io.println("requests {stats.requests} responses {stats.responses} streamed {stats.streamed}")
}
