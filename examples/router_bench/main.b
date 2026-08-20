package main

import espresso
import std.io
import std.time

fn item(context: espresso.HttpContext) -> Result<bool> {
    context.response.text(
        200, "OK", context.request.route("id").or("missing"))
    return ok(true)
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/items/\{id\}", item).expect("route")
    let host: espresso.TestHost = new espresso.TestHost(app)
    let count: int = 20000
    let started: int = time.monotonic_nanos()
    var checksum: int = 0
    for index: int in 0..count {
        let response: espresso.TestResponse =
            host.get("/items/{index}").expect("request")
        checksum += response.status + response.body.len()
    }
    let elapsed: int = time.monotonic_nanos() - started
    let per_second: int = if elapsed == 0 {
        0
    } else { count * 1000000000 / elapsed }
    io.println("espresso router {per_second} requests/s checksum {checksum}")
    host.close().expect("close")
}
