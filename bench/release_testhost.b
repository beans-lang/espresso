package main

import espresso
import std.io
import std.time

fn sync_handler(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    return espresso.text("ok")
}

async fn async_handler(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    return espresso.text("ok")
}

async fn requests_per_second(host: espresso.TestHost,
                             target: string,
                             count: int) -> Result<int> {
    let started: int = time.monotonic_nanos()
    var checksum: int = 0
    for index: int in 0..count {
        let response: espresso.TestResponse = await host.get(target)?
        checksum += response.status + response.body.len()
    }
    if checksum == 0 { return err("empty benchmark checksum", "bench") }
    let elapsed: int = time.monotonic_nanos() - started
    if elapsed <= 0 { return err("empty benchmark duration", "bench") }
    return ok(count * 1000000000 / elapsed)
}

async fn warm(host: espresso.TestHost, target: string) -> Result<bool> {
    for index: int in 0..5000 {
        await host.get(target)?
    }
    return ok(true)
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get_sync("/sync", sync_handler).expect("sync")
    app.get("/async", async_handler).expect("async")
    let host: espresso.TestHost = new espresso.TestHost(app)
    (await warm(host, "/sync")).expect("sync warmup")
    (await warm(host, "/async")).expect("async warmup")
    let sync_rate: int =
        (await requests_per_second(host, "/sync", 100000)).expect("sync sample")
    let async_rate: int =
        (await requests_per_second(host, "/async", 100000)).expect("async sample")
    io.println("sync_testhost_rps\trequests_per_second\t{sync_rate}")
    io.println("async_no_await_rps\trequests_per_second\t{async_rate}")
    host.close().expect("close")
}
