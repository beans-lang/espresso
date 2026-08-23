package main

import espresso
import std.io
import std.time

async fn handler(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    return espresso.text("ok")
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/lane", handler).expect("route")
    let host: espresso.TestHost = new espresso.TestHost(app)
    for index: int in 0..5000 {
        (await host.get("/lane")).expect("warmup")
    }
    let started: int = time.monotonic_nanos()
    var checksum: int = 0
    for index: int in 0..100000 {
        let response: espresso.TestResponse =
            (await host.get("/lane")).expect("request")
        checksum += response.status + response.body.len()
    }
    let elapsed: int = time.monotonic_nanos() - started
    if checksum == 0 || elapsed <= 0 { panic("invalid benchmark sample") }
    let rate: int = 100000 * 1000000000 / elapsed
    io.println("testhost_rps\trequests_per_second\t{rate}")
    host.close().expect("close")
}
