// The controller tax, measured: an annotated controller action against
// an identical free-function handler, same route shape, same response,
// same process, through TestHost. This is the gate the reflection and
// binding work is held to — the controller lane must stay within 2x of
// the free-function lane.
package main

import espresso
import std.io
import std.time

pub class Greeting {
    pub fn init() {}
    pub fn line(name: string) -> string { return "hello {name}" }
}

@espresso.controller(route: "/c")
pub class BenchController extends espresso.Controller {
    greeting: Greeting

    pub fn init(greeting: Greeting) { self.greeting = greeting }

    @espresso.get(route: r"/hello/{name}")
    pub fn hello(@espresso.route name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text(self.greeting.line(name))
    }
}

fn free_hello(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    let name: string = context.request.route("name").or("missing")
    return espresso.text("hello {name}")
}

fn lane(host: espresso.TestHost, label: string,
        target: string, count: int) -> Result<int> {
    var checksum: int = 0
    for _: int in 0..1000 {
        let response: espresso.TestResponse = host.get(target)?
        checksum += response.status
    }
    let started: int = time.monotonic_nanos()
    for _: int in 0..count {
        let response: espresso.TestResponse = host.get(target)?
        checksum += response.status + response.body.len()
    }
    let elapsed: int = time.monotonic_nanos() - started
    let per_second: int = if elapsed == 0 {
        0
    } else { count * 1000000000 / elapsed }
    let per_request: int = elapsed / count
    io.println(
        "{label} {per_second} req/s {per_request} ns/req checksum {checksum}")
    return ok(per_request)
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.services.singleton<Greeting>().expect("greeting")
    espresso.add_controllers(builder).expect("add")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")
    app.get(r"/f/hello/{name}", free_hello).expect("free")

    let host: espresso.TestHost = new espresso.TestHost(app)
    let count: int = 50000
    let function_lane: int =
        lane(host, "free-fn   ", "/f/hello/Ada", count).expect("free lane")
    let controller_lane: int =
        lane(host, "controller", "/c/hello/Ada", count).expect("controller lane")
    let ratio_hundredths: int =
        if function_lane == 0 { 0 }
        else { controller_lane * 100 / function_lane }
    io.println(
        "controller/free ratio {ratio_hundredths / 100}.{ratio_hundredths % 100}x")
    host.close().expect("close")
}
