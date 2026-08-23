package main

import espresso
import std.http
import std.io
import std.thread
import std.time

struct LiveSample {
    rate: int
    p99_nanos: int
    cpu_requests: int
}

fn handler(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    return espresso.text("ok")
}

fn live_client(port: int,
               control: espresso.ServerControl) -> LiveSample {
    let client: http.Client =
        http.Client.connect_timeout("127.0.0.1", port, 5000)
            .expect("connect")
    for index: int in 0..2000 {
        client.get("/live").expect("warmup")
    }
    var latencies: List<int> = []
    latencies.reserve(20000)
    var checksum: int = 0
    let started: int = time.monotonic_nanos()
    for index: int in 0..20000 {
        let request_started: int = time.monotonic_nanos()
        let response: http.ClientResponse =
            client.get("/live").expect("request")
        latencies.push(time.monotonic_nanos() - request_started)
        checksum += response.status + response.body.len()
    }
    let elapsed: int = time.monotonic_nanos() - started
    latencies.sort()
    if checksum == 0 || elapsed <= 0 { panic("invalid live benchmark sample") }
    let ignored_close: Result<bool> = client.close()
    control.stop().expect("stop")
    return LiveSample {
        rate: 20000 * 1000000000 / elapsed,
        p99_nanos: latencies[19799],
        cpu_requests: 22000,
    }
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get_sync("/live", handler).expect("route")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let client: Thread<LiveSample> = thread.spawn(fn() -> LiveSample {
        return live_client(port, control)
    })
    let ignored_stats: espresso.ServerStats =
        (await server.run()).expect("run")
    let sample: LiveSample = (await client.join_async()).expect("client")
    io.println("live_rps\trequests_per_second\t{sample.rate}")
    io.println("live_p99_nanos\tnanoseconds\t{sample.p99_nanos}")
    io.println("live_cpu_requests\trequests\t{sample.cpu_requests}")
}
