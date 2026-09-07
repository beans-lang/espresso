// Cookies: exactly which bytes a name and a value may hold, what the reader
// makes of every Cookie header shape, that a value round-trips byte for byte,
// and that a keep-alive connection never carries one request's cookies into
// the next.
package main

import espresso
import std.http
import std.io
import std.net
import std.thread

fn one_byte(byte: int) -> string {
    let raw: Bytes = new Bytes(0)
    raw.push(byte)
    return raw.to_string()
}

// The same byte with neighbours on both sides. A check that only ever sees a
// one-character string cannot tell a "first byte" rule from an "every byte"
// one.
fn embedded(byte: int) -> string {
    let raw: Bytes = new Bytes(0)
    raw.push(97)
    raw.push(98)
    raw.push(byte)
    raw.push(99)
    raw.push(100)
    return raw.to_string()
}

fn bag(context: espresso.HttpContext) -> string {
    let jar: espresso.QueryValues = context.request.cookies()
    var shown: string = "count:{jar.count()}"
    for index: int in 0..jar.count() {
        shown = "{shown} {jar.name_at(index)}={jar.value_at(index)}"
    }
    return shown
}

fn read(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text(bag(context))
}

// Answers with whatever `sid` holds, so the round trip can compare the value
// it sent against the value that came back.
fn sid(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text(context.request.cookie("sid").or("<absent>"))
}

fn write_cookies(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    let session: espresso.CookieOptions = new espresso.CookieOptions()
    session.max_age_seconds = 3600
    context.response.set_cookie("sid", "s3cr3t-token", session)?

    let readable: espresso.CookieOptions = new espresso.CookieOptions()
    readable.http_only = false
    readable.secure = false
    readable.path = "/ui"
    readable.same_site = espresso.SameSite.strict
    context.response.set_cookie("theme", "dark", readable)?

    let cleared: espresso.CookieOptions = new espresso.CookieOptions()
    cleared.max_age_seconds = 0
    context.response.set_cookie("stale", "", cleared)?
    return espresso.text("wrote")
}

// A handler whose cookie is forged: the pipeline must answer 500 and never
// serialize the header.
fn forged(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let options: espresso.CookieOptions = new espresso.CookieOptions()
    context.response.set_cookie("sid", "a; Secure=no", options)?
    return espresso.text("unreachable")
}

// ---- which bytes are legal --------------------------------------------------

fn accepted(name: string, value: string) -> bool {
    let safe: espresso.CookieOptions = new espresso.CookieOptions()
    return espresso.set_cookie_value(name, value, safe).is_ok()
}

fn byte_rules() {
    // A cookie name is an RFC 9110 token; a cookie value is RFC 6265's
    // cookie-octet. Both are swept over the whole byte range, alone and
    // surrounded, so a rule that only guards the first byte fails here.
    var name_alone: string = ""
    var name_count: int = 0
    var name_position_splits: int = 0
    var value_alone: string = ""
    var value_count: int = 0
    var value_position_splits: int = 0
    for byte: int in 0..256 {
        let solo: string = one_byte(byte)
        let inner: string = embedded(byte)

        let name_solo: bool = accepted(solo, "v")
        if name_solo != accepted(inner, "v") { name_position_splits += 1 }
        if name_solo {
            name_count += 1
            if byte > 32 && byte < 127 { name_alone = "{name_alone}{solo}" }
        }

        let value_solo: bool = accepted("sid", solo)
        if value_solo != accepted("sid", inner) {
            value_position_splits += 1
        }
        if value_solo {
            value_count += 1
            if byte > 32 && byte < 127 { value_alone = "{value_alone}{solo}" }
        }
    }
    io.println("name bytes {name_count} position-splits {name_position_splits}")
    io.println("name set [{name_alone}]")
    io.println("value bytes {value_count} position-splits {value_position_splits}")
    io.println("value set [{value_alone}]")
    // An empty value is a present, empty cookie; an empty name is not a name.
    io.println("empty value {accepted("sid", "")} empty name {accepted("", "v")}")
}

fn shown(name: string, value: string,
         options: espresso.CookieOptions) -> string {
    match espresso.set_cookie_value(name, value, options) {
        ok(built) => { return "ok [{built}]" }
        err(problem) => { return "refused {problem.kind}: {problem.msg}" }
    }
}

fn attribute_rules() {
    let split_path: espresso.CookieOptions = new espresso.CookieOptions()
    split_path.path = "/a; Secure"
    io.println("path-semicolon {shown("sid", "v", split_path)}")

    let comma_path: espresso.CookieOptions = new espresso.CookieOptions()
    comma_path.path = "/a,/b"
    io.println("path-comma {shown("sid", "v", comma_path)}")

    let split_domain: espresso.CookieOptions = new espresso.CookieOptions()
    split_domain.domain = "x.test\r\nSet-Cookie: evil=1"
    io.println("domain-crlf {shown("sid", "v", split_domain)}")

    let cross: espresso.CookieOptions = new espresso.CookieOptions()
    cross.same_site = espresso.SameSite.none
    io.println("samesite-none-secure {shown("sid", "v", cross)}")
    cross.secure = false
    io.println("samesite-none-insecure {shown("sid", "v", cross)}")

    let bare: espresso.CookieOptions = new espresso.CookieOptions()
    bare.path = ""
    bare.http_only = false
    bare.secure = false
    io.println("bare {shown("sid", "v", bare)}")

    let full: espresso.CookieOptions = new espresso.CookieOptions()
    full.path = "/app"
    full.domain = "app.test"
    full.max_age_seconds = 60
    full.same_site = espresso.SameSite.strict
    io.println("full {shown("sid", "v", full)}")

    let deleted: espresso.CookieOptions = new espresso.CookieOptions()
    deleted.max_age_seconds = 0
    io.println("deleted {shown("sid", "", deleted)}")
}

// ---- the round trip ---------------------------------------------------------

// Everything set_cookie accepts must come back from cookie() unchanged:
// nothing is encoded on the way out, so nothing may be decoded on the way in.
fn round_trip(host: espresso.TestHost) {
    let payloads: List<string> =
        ["", "!", "#$%&'()*+", "-./0123456789:",
         "<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[",
         r"]^_`abcdefghijklmnopqrstuvwxyz{|}~",
         "s3cr3t-token", "AAAA.BBBB.CCCC", "eyJhbGciOiJIUzI1NiJ9",
         "%7Bnot-decoded%7D", "100%", "==", "a", "aa", "aaa"]
    var mismatches: int = 0
    var refused: int = 0
    let options: espresso.CookieOptions = new espresso.CookieOptions()
    for payload: string in payloads {
        match espresso.set_cookie_value("sid", payload, options) {
            err(_) => { refused += 1 }
            ok(built) => {
                // The pair is everything before the first attribute — exactly
                // what a browser echoes back in the Cookie header.
                var pair: string = built
                match built.find(";") {
                    some(at) => { pair = built.slice(0, at) }
                    none => {}
                }
                let headers: http.Headers = new http.Headers()
                headers.add("Cookie", pair)
                let answer: espresso.TestResponse = host.send_with_headers(
                    "GET", "/sid", headers, "").expect("round trip")
                if answer.text() != payload { mismatches += 1 }
            }
        }
    }
    io.println("round-trip {payloads.len()} refused {refused} mismatches {mismatches}")
}

// ---- what the reader accepts -------------------------------------------------

fn reading(host: espresso.TestHost) {
    let cases: List<string> =
        ["sid=one",
         "sid=one; theme=dark",
         "  sid=one ;   theme=dark  ",
         "sid=one;;theme=dark",
         "sid=one; sid=two",
         "empty=; sid=one",
         "novalue; sid=one",
         "=orphan; sid=one",
         "sid=a=b=c",
         "\tsid=one\t",
         ""]
    for raw: string in cases {
        let headers: http.Headers = new http.Headers()
        if raw != "" { headers.add("Cookie", raw) }
        let answer: espresso.TestResponse =
            host.send_with_headers("GET", "/read", headers, "").expect("read")
        io.println("[{raw}] -> {answer.text()}")
    }

    // Two Cookie headers: legal over HTTP/2, and rejoined by proxies. The
    // second is spelled lowercase, which is what an HTTP/2 client sends.
    let split: http.Headers = new http.Headers()
    split.add("Cookie", "sid=one")
    split.add("cookie", "theme=dark")
    io.println("two-headers {host.send_with_headers("GET", "/read", split, "").expect("split").text()}")
}

// ---- a real connection --------------------------------------------------------

// One keep-alive connection carrying four requests. The server reuses one
// HttpRequest per connection, so a cookie cache that is not reset between
// messages makes the second request see the first one's cookies. With one
// request per connection that bug is invisible, which is why this is four.
fn client(port: int, control: espresso.ServerControl) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            let first: string =
                "GET /read HTTP/1.1\r\nHost: h\r\nCookie: sid=one; theme=dark\r\n\r\n"
            let second: string = "GET /read HTTP/1.1\r\nHost: h\r\n\r\n"
            let third: string = "GET /write HTTP/1.1\r\nHost: h\r\n\r\n"
            let fourth: string =
                "GET /read HTTP/1.1\r\nHost: h\r\nCookie: sid=three\r\nConnection: close\r\n\r\n"
            match stream.write_text("{first}{second}{third}{fourth}") {
                ok(_) => {}
                err(error) => { return "write failed {error.kind}" }
            }
            let raw: string =
                stream.read_to_end(65536).or(new Bytes(0)).to_string()
            let stopped: bool = control.stop().or(false)
            var report: string = ""
            for expected: string in ["count:2 sid=one theme=dark",
                                     "count:0",
                                     "count:1 sid=three"] {
                let seen: int = raw.split(expected).len() - 1
                report = "{report}[{expected}]x{seen} "
            }
            let cookies_set: int = raw.split("Set-Cookie: ").len() - 1
            return "{report}set-cookie {cookies_set} stopped {stopped}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "connect failed {error.kind}"
        }
    }
}

fn main() {
    byte_rules()
    attribute_rules()

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/read", read).expect("read")
    app.get("/sid", sid).expect("sid")
    app.get("/write", write_cookies).expect("write")
    app.get("/forged", forged).expect("forged")

    let host: espresso.TestHost = new espresso.TestHost(app)
    round_trip(host)
    reading(host)

    let wrote: espresso.TestResponse = host.get("/write").expect("write")
    for value: string in wrote.headers.all("Set-Cookie") {
        io.println("set {value}")
    }
    let broken: espresso.TestResponse = host.get("/forged").expect("forged")
    io.println("forged status {broken.status} headers {broken.headers.all("Set-Cookie").len()}")
    host.close().expect("close")

    // The same routes over a real socket, on one keep-alive connection.
    let builder2: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app2: espresso.WebApplication = builder2.build().expect("app2")
    app2.get("/read", read).expect("read2")
    app2.get("/write", write_cookies).expect("write2")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    let server: espresso.WebServer =
        espresso.WebServer.bind(app2, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println(visitor.join())
    io.println("requests {stats.requests} responses {stats.responses} errors {stats.connection_errors}")
}
