package main

import espresso
import std.os

// The wrk workload: four workers behind the acceptor handoff, one
// static text route on the sync fast path and one async route that
// suspends once, mirroring the framework's two handler classes.
fn build_app() -> Result<espresso.WebApplication> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get_sync("/", fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        return espresso.text("hello from espresso")
    })?
    app.get("/async", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        return espresso.text("hello from espresso")
    })?
    return ok(app)
}

async fn main() {
    var workers: int = 4
    match os.env("ESPRESSO_WORKERS") {
        some(text) => { workers = text.to_int().or(4) }
        none => {}
    }
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.host = "127.0.0.1"
    options.port = 8098
    var factories: List<send fn() -> Result<espresso.WebApplication>> = []
    for index: int in 0..workers {
        factories.push(build_app)
    }
    (await espresso.serve(options, move factories)).expect("serve")
}
