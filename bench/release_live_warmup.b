package main

import espresso
import std.http
import std.thread

fn handler(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    return espresso.text("ok")
}

fn warm_client(port: int, control: espresso.ServerControl) -> bool {
    let client: http.Client =
        http.Client.connect_timeout("127.0.0.1", port, 5000)
            .expect("connect")
    var checksum: int = 0
    for index: int in 0..2000 {
        let response: http.ClientResponse =
            client.get("/live").expect("warmup")
        checksum += response.status + response.body.len()
    }
    let ignored_close: Result<bool> = client.close()
    control.stop().expect("stop")
    return checksum > 0
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
    let client: Thread<bool> = thread.spawn(fn() -> bool {
        return warm_client(port, control)
    })
    let ignored_stats: espresso.ServerStats =
        (await server.run()).expect("run")
    if !(await client.join_async()).expect("client") {
        panic("empty warmup checksum")
    }
}
