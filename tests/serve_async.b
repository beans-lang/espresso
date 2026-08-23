package main

import espresso
import std.io

fn live_app() -> Result<espresso.WebApplication> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    return builder.build()
}

fn failed_app() -> Result<espresso.WebApplication> {
    return err("planned worker startup failure", "startup")
}

async fn main() {
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    var factories: List<send fn() -> Result<espresso.WebApplication>> = []
    factories.push(live_app)
    factories.push(failed_app)
    match await espresso.serve(options, move factories) {
        ok(_) => { io.println("serve unexpectedly succeeded") }
        err(problem) => { io.println("serve stopped {problem.kind}") }
    }
}
