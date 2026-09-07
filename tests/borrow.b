package main

// The response borrows the handler's payload instead of copying it into a
// per-connection buffer (beans-lang/beans#140). A string body is held by
// reference, so `response.body` — the bytes-form buffer that used to grow to
// the payload size and keep that megabyte resident on every connection — stays
// empty; a Bytes body is moved in and owns `response.body`. This asserts that
// split deterministically, independent of any memory measurement: reverting
// text_body to copy the string into `body` turns the text row's `raw 0` into
// `raw 20000`, and the golden goes red.

import espresso
import std.http
import std.io
import std.net

const N: int = 20000   // over the 16384 vectored threshold, so this is a large body

fn make_text(n: int) -> string {
    let block: Bytes = new Bytes(0)
    block.reserve(1000)
    var i: int = 0
    for i < 1000 {
        block.push(97 + (i % 26))
        i += 1
    }
    let out: Bytes = new Bytes(0)
    out.reserve(n)
    var done: int = 0
    for done + 1000 <= n {
        out.append(block)
        done += 1000
    }
    for done < n {
        out.push(97 + ((done % 1000) % 26))
        done += 1
    }
    return out.to_string()
}

fn main() {
    let big: string = make_text(N)
    let r: espresso.HttpResponse = new espresso.HttpResponse()

    // A string body: borrowed, so the bytes buffer never grows to it.
    r.text_body(200, "OK", big, "text/plain; charset=utf-8")
    io.println("text: istext {r.is_text_body()} raw {r.body.len()} payload {r.body_len()} match {r.body_bytes().to_string() == big}")

    // A Bytes body: moved in, so it owns the bytes buffer.
    r.bytes(200, "OK", Bytes.from(big), "application/octet-stream")
    io.println("bytes: istext {r.is_text_body()} raw {r.body.len()} payload {r.body_len()} match {r.body_bytes().to_string() == big}")

    // Switching to a string body drops the prior bytes payload rather than
    // keeping its capacity.
    r.text_body(200, "OK", "small", "text/plain; charset=utf-8")
    io.println("switch: istext {r.is_text_body()} raw {r.body.len()} payload {r.body_len()}")

    // 204 carries neither form.
    r.no_content()
    io.println("nocontent: istext {r.is_text_body()} raw {r.body.len()} payload {r.body_len()}")

    // ---- the two paths that used to copy their payload to hand it on ------
    //
    // These need a real HttpContext, which only the application can make, so
    // they run one request through app.handle and then answer that context by
    // hand. Both are about which form the response ends up holding, which is
    // exactly what this file exists to pin, and neither is visible from a
    // socket: the wire bytes are identical either way.
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    let served: http.ServedRequest = new http.ServedRequest()
    served.head.method = "POST"
    served.head.target = "/unmapped"
    let context: espresso.HttpContext =
        app.handle(served, new net.Address("127.0.0.1", 1)).expect("context")

    // A validation problem is the string json.stringify built, held by
    // reference. It used to be copied into a Bytes first, which showed up here
    // as `istext false` and a non-zero `raw`.
    let errors: espresso.ValidationErrors = new espresso.ValidationErrors()
    errors.add("text", "text is required", "required")
    let problem: bool =
        espresso.write_validation_problem(context, errors).expect("problem")
    io.println("validation: istext {context.response.is_text_body()} raw {context.response.body.len()} payload {context.response.body_len()}")

    // A BytesResult hands its payload to the response instead of copying it,
    // so after execute the response owns the bytes and the result has none
    // left — and says so instead of answering a second request with nothing.
    let carrier: espresso.BytesResult = new espresso.BytesResult(
        200, Bytes.from(big), "application/octet-stream")
    let first: bool = carrier.execute(context).expect("execute")
    io.println("bytesresult: istext {context.response.is_text_body()} raw {context.response.body.len()} match {context.response.body_bytes().to_string() == big}")
    io.println("bytesresult again: ok {carrier.execute(context).is_ok()}")

    let closed: Result<bool> = context.close()
}
