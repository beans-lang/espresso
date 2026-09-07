// Protocol upgrades: the middleware pipeline runs first, the connection fiber
// gives the socket away exactly once, and everything that is not an upgrade
// on this connection still gets an ordinary HTTP answer.
package main

import espresso
import std.encoding.base64
import std.http
import std.io
import std.net
import std.thread
import std.websocket

// ---- the server side ---------------------------------------------------------

// Owns the socket for the rest of its life. It greets with what the pipeline
// saw — the captured route value and the session cookie — so a client can
// prove from the outside that routing and cookie parsing happened on the
// upgrade path and not only on the ordinary one.
pub class EchoSocket implements espresso.UpgradeHandler {
    label: string

    pub fn init(label: string) { self.label = label }

    pub fn upgrade(context: espresso.HttpContext,
                   request: http.Request,
                   move stream: net.TcpStream) -> Result<bool> {
        let room: string = context.request.route("room").or("-")
        let session: string = context.request.cookie("sid").or("-")
        // std.websocket reads through `TcpStream.read`, which does not park on
        // a fiber, and espresso hands the socket over exactly as the
        // connection loop left it: non-blocking and registered with the fiber
        // netpoller. Restoring blocking mode is what makes those reads work,
        // and it costs this worker thread for as long as the socket lives —
        // see the note on espresso.UpgradeHandler.
        stream.set_nonblocking(false)?
        let socket: websocket.Connection =
            websocket.Connection.accept(move stream, request)?
        socket.send_text("hello {self.label} room={room} sid={session}")?
        var rounds: int = 0
        for rounds < 8 {
            rounds += 1
            match socket.receive()? {
                none => { break }
                some(message) => {
                    match message {
                        text(body) => {
                            if body == "bye" { break }
                            socket.send_text("echo:{body}")?
                        }
                        binary(data) => {
                            socket.send_text("bytes:{data.len()}")?
                        }
                        ping(data) => {}
                        pong(data) => {}
                        closed(code, reason) => { break }
                    }
                }
            }
        }
        let ended: Result<bool> = socket.close(1000, "done")
        return ok(true)
    }
}

// Panics while holding the socket. The connection fiber has already given the
// socket away, so the only correct outcome is a contained panic that ends this
// one connection and leaves the server accepting.
pub class PanicSocket implements espresso.UpgradeHandler {
    pub fn init() {}

    pub fn upgrade(context: espresso.HttpContext,
                   request: http.Request,
                   move stream: net.TcpStream) -> Result<bool> {
        stream.set_nonblocking(false)?
        let socket: websocket.Connection =
            websocket.Connection.accept(move stream, request)?
        socket.send_text("about to fail")?
        panic("the upgrade handler blew up")
    }
}

// A protocol that is not WebSocket, driven the way a fiber wants: the socket
// stays non-blocking and every read parks in the netpoller instead of holding
// the worker thread. It exists to prove two things at once — that the
// hand-off carries no assumption about which protocol comes next, and that a
// handler which parks is served correctly by the socket it is given.
pub class LineSocket implements espresso.UpgradeHandler {
    pub fn init() {}

    pub fn upgrade(context: espresso.HttpContext,
                   request: http.Request,
                   move stream: net.TcpStream) -> Result<bool> {
        let tag: string = context.request.route("tag").or("-")
        // A message that declared a body still delivers it as body events
        // before the upgrade, so the handler sees the HTTP request whole.
        let carried: string = context.request.body.to_string()
        stream.write_text(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: line\r\nConnection: Upgrade\r\n\r\n")?
        stream.write_text("line-ready {tag} body[{carried}]\n")?
        let buffer: Bytes = new Bytes(4096)
        var rounds: int = 0
        for rounds < 8 {
            rounds += 1
            // read_into parks this fiber in the netpoller; the worker thread
            // stays free for every other connection on it.
            let count: int = stream.read_into(buffer)?
            if count == 0 { break }
            let piece: string = buffer.slice(0, count).to_string()
            if piece.starts_with("quit") { break }
            stream.write_text("said:{piece}")?
        }
        stream.write_text("line-done\n")?
        return stream.close()
    }
}

// Never touches the socket at all. The moved parameter dies with the frame,
// which must close the descriptor rather than leak it.
pub class DroppingSocket implements espresso.UpgradeHandler {
    pub fn init() {}

    pub fn upgrade(context: espresso.HttpContext,
                   request: http.Request,
                   move stream: net.TcpStream) -> Result<bool> {
        return ok(true)
    }
}

fn plain(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("plain-body")
}

// An ordinary GET route sharing a path with an upgrade endpoint. A browser
// that opens the page and then the socket hits both.
fn ws_page(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("page-for-ws")
}

// Runs on every request, upgrade or not. It refuses a foreign Origin, which
// is the check a cross-site WebSocket hijack needs skipped — so a handshake
// that skipped the pipeline would sail past it.
fn origin_guard(context: espresso.HttpContext,
                next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
    match context.request.headers.get("Origin") {
        some(origin) => {
            if origin != "https://good.test" {
                context.response.text(403, "Forbidden", "bad origin")
                return ok(true)
            }
        }
        none => {}
    }
    // A layer that arms a Responder on a request which is about to give its
    // socket away leaves the connection waiting for a payload it can no longer
    // frame. The application refuses the request instead of hanging.
    if context.request.path == "/ws/deferred" {
        let responder: espresso.Responder =
            context.respond_later().expect("responder")
    }
    return next(context)
}

// ---- a hand-written client ----------------------------------------------------

// The handshake by hand, so the test can put anything it likes in the request
// head: a cookie, an Origin, trailing bytes, a whole pipelined request in
// front of it.
fn handshake_head(target: string, extra: string) -> string {
    return "GET {target} HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n{extra}\r\n"
}

// A client that keeps what it over-read.
//
// The 101 head and the first frame after it are written back to back and
// arrive in one TCP segment as often as not, so a reader that stops at the
// blank line and then asks the socket for two more bytes waits forever for
// bytes it already has. That is timing, not logic: it showed as a native-only
// failure while the interpreter's slower loop happened to split the reads.
// Everything here reads through one pending buffer instead.
class Peer {
    stream: net.TcpStream
    pending: Bytes = new Bytes(0)

    fn init(move stream: net.TcpStream) {
        self.stream = move stream
    }

    fn fill() -> bool {
        match self.stream.read(4096) {
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

    // Everything up to and including the blank line; what follows stays
    // pending for the next reader.
    fn head() -> string {
        var rounds: int = 0
        for rounds < 64 {
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

    fn exactly(count: int) -> Option<Bytes> {
        var rounds: int = 0
        for self.pending.len() < count {
            rounds += 1
            if rounds > 64 { break }
            if !self.fill() { break }
        }
        if self.pending.len() < count { return none }
        let out: Bytes = self.pending.slice(0, count)
        self.drop_front(count)
        return some(move out)
    }

    // Whatever has arrived, waiting once for it if nothing has.
    fn chunk() -> string {
        if self.pending.len() == 0 {
            let more: bool = self.fill()
        }
        let out: string = self.pending.to_string()
        self.pending = new Bytes(0)
        return out
    }

    fn rest() -> string {
        var rounds: int = 0
        for rounds < 64 {
            rounds += 1
            if !self.fill() { break }
        }
        let out: string = self.pending.to_string()
        self.pending = new Bytes(0)
        return out
    }

    // One unmasked server text frame with a payload under 126 bytes — which
    // every greeting in this test is. A server never masks, so this is the
    // whole decoder that case needs.
    fn frame() -> string {
        match self.exactly(2) {
            none => { return "<no frame>" }
            some(header) => {
                if header.get(0) != 129 { return "<opcode {header.get(0)}>" }
                let length: int = header.get(1) % 128
                if length >= 126 { return "<frame too long>" }
                if length == 0 { return "" }
                match self.exactly(length) {
                    some(payload) => { return payload.to_string() }
                    none => { return "<short frame>" }
                }
            }
        }
    }

    fn close() -> bool {
        return self.stream.close().is_ok()
    }
}

// The text of one received message, or a word saying what came instead.
fn text_of(arrived: Result<Option<websocket.Message>>) -> string {
    match arrived {
        err(problem) => { return "<err {problem.kind}>" }
        ok(maybe) => {
            match maybe {
                none => { return "<none>" }
                some(message) => {
                    return match message {
                        text(body) => body,
                        binary(data) => "<binary {data.len()}>",
                        ping(data) => "<ping>",
                        pong(data) => "<pong>",
                        closed(code, reason) => "<closed {code}>",
                    }
                }
            }
        }
    }
}

fn dial(port: int) -> Result<Peer> {
    let stream: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 3000)?
    stream.set_timeouts(3000, 3000)?
    return ok(new Peer(move stream))
}

fn status_line(head: string) -> string {
    if head == "" { return "<closed with no answer>" }
    match head.find("\r\n") {
        some(at) => { return head.slice(0, at) }
        none => { return head }
    }
}

// The whole exchange for one raw case: connect, send `request`, read the
// response head, and — when it is a 101 — the first frame that follows.
fn raw_case(port: int, request: string, want_frame: bool) -> string {
    match dial(port) {
        err(problem) => { return "connect failed {problem.kind}" }
        ok(peer) => {
            if !peer.send(request) { return "write failed" }
            var report: string = status_line(peer.head())
            if want_frame && report.contains("101") {
                report = "{report} | {peer.frame()}"
            }
            let closed: bool = peer.close()
            return report
        }
    }
}

// Every status line the server sent on one connection, so a case can assert
// the ORDER responses came out in and not only the first of them. It reads
// until it has seen `wanted` of them rather than a fixed number of reads,
// because a pipelined batch may arrive in one segment or in several.
fn status_lines(port: int, request: string, wanted: int) -> string {
    match dial(port) {
        err(problem) => { return "connect failed {problem.kind}" }
        ok(peer) => {
            if !peer.send(request) { return "write failed" }
            var rounds: int = 0
            for rounds < 16 {
                rounds += 1
                let seen: int =
                    peer.pending.to_string().split("HTTP/1.1 ").len() - 1
                if seen >= wanted { break }
                if !peer.fill() { break }
            }
            var found: List<string> = []
            for piece: string in peer.pending.to_string().split("HTTP/1.1 ") {
                match piece.find("\r\n") {
                    some(at) => { found.push(piece.slice(0, at)) }
                    none => {}
                }
            }
            let closed: bool = peer.close()
            return found.join(" then ")
        }
    }
}

// One line-protocol exchange over the non-WebSocket upgrade endpoint.
fn line_case(port: int) -> string {
    match dial(port) {
        err(problem) => { return "connect failed {problem.kind}" }
        ok(peer) => {
            let request: string =
                "{handshake_head("/raw/alpha", "Upgrade: line\r\nContent-Length: 5\r\n")}HELLO"
            if !peer.send(request) { return "write failed" }
            let report: string = status_line(peer.head())
            let greeting: string = peer.chunk()
            let asked: bool = peer.send("ping-1")
            let echoed: string = peer.chunk()
            let quit: bool = peer.send("quit")
            let tail: string = peer.rest()
            let closed: bool = peer.close()
            return "{report} | {greeting.trim()} | {echoed.trim()} | {tail.trim()}"
        }
    }
}

// ---- the scenarios ------------------------------------------------------------

fn client(port: int, control: espresso.ServerControl) -> string {
    var lines: List<string> = []

    // 1. The handshake, with a route parameter, through the library client —
    //    a real WebSocket carried over the socket espresso gave away, not
    //    just a 101 status line.
    match websocket.Connection.connect("127.0.0.1", port, "/ws/lobby") {
        err(problem) => { lines.push("library connect failed {problem.kind}") }
        ok(socket) => {
            lines.push("greeting {text_of(socket.receive())}")
            let sent: Result<bool> = socket.send_text("one")
            lines.push("echo {text_of(socket.receive())}")
            let again: Result<bool> = socket.send_text("two")
            lines.push("echo {text_of(socket.receive())}")
            let farewell: Result<bool> = socket.send_text("bye")
            let done: Result<bool> = socket.close(1000, "client done")
        }
    }

    // 2. The same endpoint by hand, carrying a cookie and a good Origin. The
    //    greeting proves the route value and the cookie reached the handler.
    lines.push("cookie+origin {raw_case(port, handshake_head("/ws/lobby", "Origin: https://good.test\r\nCookie: sid=abc123\r\n"), true)}")

    // 3. A foreign Origin. The middleware answers and the socket stays HTTP.
    lines.push("bad-origin {raw_case(port, handshake_head("/ws/lobby", "Origin: https://evil.test\r\n"), false)}")

    // 4. A path with no upgrade endpoint. The parser has already stopped, so
    //    there is no serving this request as an ordinary GET.
    lines.push("no-endpoint {raw_case(port, handshake_head("/plain", ""), false)}")

    // 5. Bytes after the handshake: the next protocol's frames, arriving
    //    before this server agreed there would be a next protocol.
    lines.push("remainder {raw_case(port, "{handshake_head("/ws/lobby", "")}GARBAGE", false)}")

    // 6. A pipelined GET in front of the handshake. Its response was framed
    //    into the output queue before the upgrade was even parsed, and it must
    //    reach the client ahead of the 101 — after the hand-off there is
    //    nothing left to send it with.
    lines.push("pipelined {status_lines(port, "{"GET /plain HTTP/1.1\r\nHost: h\r\n\r\n"}{handshake_head("/ws/lobby", "")}", 3)}")

    // 6b. The same two requests, but the client waits for the first answer
    //     before asking to upgrade: an upgrade arriving as the second message
    //     of a keep-alive connection, on a context that has already served
    //     one request and recycled its head.
    match dial(port) {
        err(problem) => { lines.push("sequential connect failed {problem.kind}") }
        ok(peer) => {
            let first: bool = peer.send("GET /plain HTTP/1.1\r\nHost: h\r\n\r\n")
            let head_one: string = status_line(peer.head())
            let body_one: string = peer.chunk()
            let second: bool = peer.send(handshake_head("/ws/lobby", ""))
            let head_two: string = status_line(peer.head())
            let greeting: string = peer.frame()
            let closed: bool = peer.close()
            lines.push("sequential {head_one} [{body_one}] then {head_two} | {greeting}")
        }
    }

    // 6c. Two more shapes llhttp reports as an upgrade: a CONNECT, and an
    //     HTTP/2 cleartext upgrade. Neither has an endpoint here, and neither
    //     may be served as an ordinary request — the parser has stopped.
    lines.push("connect {raw_case(port, "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n", false)}")
    lines.push("h2c {raw_case(port, "GET /plain HTTP/1.1\r\nHost: h\r\nConnection: Upgrade, HTTP2-Settings\r\nUpgrade: h2c\r\nHTTP2-Settings: AAMAAABkAARAAAAAAAIAAAAA\r\n\r\n", false)}")

    // 6d. A middleware that armed a Responder on an upgrade request. There is
    //     no socket left to frame its answer onto, so the request is refused
    //     rather than left waiting.
    lines.push("deferred {raw_case(port, handshake_head("/ws/deferred", ""), false)}")

    // 7. A handler that panics while holding the socket.
    lines.push("panicking {raw_case(port, handshake_head("/ws/boom", ""), true)}")

    // 8. A handler that never touches the socket: the moved parameter dies
    //    with the frame and the client sees a closed connection, not a hang.
    lines.push("dropped {raw_case(port, handshake_head("/ws/drop", ""), false)}")

    // 9. A protocol that is not WebSocket, whose handler parks on every read,
    //    reached by a message that also declared a request body.
    lines.push("line {line_case(port)}")

    // 10. The ordinary route at the upgrade path is still an ordinary route.
    lines.push("plain-get {raw_case(port, "GET /ws/lobby HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n", false)}")

    let stopped: bool = control.stop().or(false)
    return lines.join("\n")
}

fn main() {
    io.println("websocket bridge {websocket.available()}")

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.use(origin_guard).expect("guard")
    app.get("/plain", plain).expect("plain")
    app.get(r"/ws/{room}", ws_page).expect("page")
    app.map_upgrade(r"/ws/{room}", new EchoSocket("echo")).expect("ws")
    app.map_upgrade(r"/raw/{tag}", new LineSocket()).expect("line")
    app.map_upgrade("/ws/boom", new PanicSocket()).expect("boom")
    app.map_upgrade("/ws/drop", new DroppingSocket()).expect("drop")
    app.map_upgrade("/ws/deferred", new EchoSocket("deferred")).expect("deferred")

    // Registration refuses the same shape twice, the way routes do.
    match app.map_upgrade(r"/ws/{other}", new EchoSocket("second")) {
        ok(_) => { io.println("duplicate accepted (wrong)") }
        err(problem) => { io.println("duplicate {problem.kind}") }
    }
    match app.map_upgrade("relative", new EchoSocket("bad")) {
        ok(_) => { io.println("relative accepted (wrong)") }
        err(problem) => { io.println("relative {problem.kind}") }
    }

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
    io.println("accepted {stats.accepted} requests {stats.requests} responses {stats.responses} upgrades {stats.upgrades}")
}
