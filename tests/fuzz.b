package main

import espresso
import std.http
import std.io
import std.net

fn endpoint(context: espresso.HttpContext) -> Result<bool> {
    context.response.text(200, "OK", context.request.path)
    return ok(true)
}

fn request(target: string) -> http.ServedRequest {
    let served: http.ServedRequest = new http.ServedRequest()
    served.head.method = "GET"
    served.head.target = target
    return served
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/\{*path\}", endpoint).expect("catch all")

    let invalid: List<string> = [
        "", "relative", "/bad%", "/bad%2", "/bad%GG",
        "/bad%00", "/bad#fragment",
    ]
    var refused: int = 0
    for target: string in invalid {
        match app.handle(
                request(target), new net.Address("127.0.0.1", 1)) {
            ok(context) => { context.close().expect("close") }
            err(_) => { refused += 1 }
        }
    }

    let valid: List<string> = [
        "/", "/hello", "/hello%20world", "/a//b", "/q?x=%2B+y",
    ]
    var accepted: int = 0
    for target: string in valid {
        match app.handle(
                request(target), new net.Address("127.0.0.1", 1)) {
            ok(context) => {
                if context.response.status == 200 { accepted += 1 }
                context.close().expect("close")
            }
            err(_) => {}
        }
    }
    io.println("targets refused {refused} accepted {accepted}")
    match app.get("/\{*other\}", endpoint) {
        ok(_) => io.println("conflict accepted"),
        err(error) => io.println("conflict {error.kind}"),
    }
    app.close().expect("close app")
}
