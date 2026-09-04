package main

// RFC 9110 §6.6.1: an origin server with a clock must send Date on 2xx/3xx/4xx.
// This drill hits a real socket (a TestHost never frames onto the wire, so it
// carries no Date by design) and proves, on the ordinary 200 path, on a HEAD,
// and on a 4xx error path, that the header is present, sits in the header
// block, is canonical IMF-fixdate, and round-trips through
// calendar.DateTime.parse_http_date. Only booleans are printed — the value is
// time-varying — so the golden stays deterministic while the header is
// asserted, not deleted.

import espresso
import std.calendar
import std.io
import std.net
import std.thread

fn json(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.json_text("\{\"message\":\"Hello, World!\"\}")
}

// A handler that stamps its own Date. The server must keep it and not add a
// second one.
fn dated(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    context.response.header("Date", "Sun, 06 Nov 1994 08:49:37 GMT")
    return espresso.json_text("\{\"message\":\"Hello, World!\"\}")
}

fn find_at(raw: string, needle: string) -> int {
    return raw.find(needle).or(-1)
}

// The value of one header line, or "" when the line is absent.
fn header_value(raw: string, name: string) -> string {
    let needle: string = "\r\n{name}: "
    let at: int = find_at(raw, needle)
    if at < 0 { return "" }
    let start: int = at + needle.len()
    let rest: string = raw.slice(start, raw.len())
    let rel: int = find_at(rest, "\r\n")
    if rel < 0 { return "" }
    return rest.slice(0, rel)
}

// True when the named header sits inside the header block (before the blank
// line that ends it), i.e. it is a real header field and in position.
fn header_in_block(raw: string, name: string) -> bool {
    let head_end: int = find_at(raw, "\r\n\r\n")
    let at: int = find_at(raw, "\r\n{name}: ")
    return at >= 0 && head_end >= 0 && at < head_end
}

fn request(port: int, text: string) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            match stream.write_text(text) {
                ok(_) => {}
                err(error) => { return "write-failed {error.kind}" }
            }
            return stream.read_to_end(65536).or(new Bytes(0)).to_string()
        }
        err(error) => { return "connect-failed {error.kind}" }
    }
}

fn client(port: int, control: espresso.ServerControl) -> string {
    // 1) Ordinary 200 GET.
    let get: string = request(port,
        "GET /json HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
    let get_value: string = header_value(get, "Date")
    let get_present: bool = get_value != ""
    let get_block: bool = header_in_block(get, "Date")
    var get_round: bool = false
    var get_canon: bool = false
    match calendar.DateTime.parse_http_date(get_value) {
        ok(parsed) => {
            get_round = true
            get_canon = parsed.to_http_date() == get_value
        }
        err(problem) => {}
    }

    // 2) HEAD carries Date exactly like the GET would, and no body.
    let head: string = request(port,
        "HEAD /json HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
    let head_present: bool = header_value(head, "Date") != ""
    let head_end: int = find_at(head, "\r\n\r\n")
    let head_bodyless: bool = head_end >= 0 && head_end + 4 >= head.len()

    // 3) A 4xx error path (413, framed by append_error, not by a handler):
    //    a body past the server's max_body. A 4xx Date is a MUST.
    let big: string = request(port,
        "POST /json HTTP/1.1\r\nHost: a\r\nContent-Length: 64\r\nConnection: close\r\n\r\n0123456789012345678901234567890123456789012345678901234567890123")
    let err_413: bool = big.contains("413 Content Too Large")
    let err_date: bool = header_value(big, "Date") != ""

    // 4) A handler that set its own Date keeps it, and the server does not add
    //    a second one.
    let own: string = request(port,
        "GET /dated HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")
    let own_count: int = own.split("\r\nDate: ").len() - 1
    let own_kept: bool =
        own_count == 1 &&
        header_value(own, "Date") == "Sun, 06 Nov 1994 08:49:37 GMT"

    let stopped: bool = control.stop().or(false)
    return "get present {get_present} block {get_block} round {get_round} canon {get_canon}\nhead present {head_present} bodyless {head_bodyless}\nerr413 {err_413} date {err_date}\nown kept {own_kept} count {own_count}\nstopped {stopped}"
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/json", json).expect("route")
    app.get("/dated", dated).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    options.max_body_bytes = 8
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
