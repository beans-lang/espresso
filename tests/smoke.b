package main

import espresso
import std.io
import std.net
import std.thread

pub class SmokeGreeting {
    pub fn init() {}
    pub fn text(name: string) -> string { return "smoke {name}" }
}

@espresso.controller(route: "/api")
pub class SmokeController {
    greeting: SmokeGreeting

    pub fn init(greeting: SmokeGreeting) { self.greeting = greeting }

    @espresso.http_get(route: "/hello/\{name\}")
    pub fn hello(context: espresso.HttpContext) -> Result<bool> {
        context.response.text(
            200, "OK", self.greeting.text(
                context.request.route("name").or("missing")))
        return ok(true)
    }
}

fn live_handler(context: espresso.HttpContext) -> Result<bool> {
    context.response.text(200, "OK", "live")
    return ok(true)
}

fn live_client(port: int, control: espresso.ServerControl) -> bool {
    let stream: net.TcpStream = net.TcpStream.connect_timeout(
        "127.0.0.1", port, 3000).expect("connect")
    stream.write_text(
        "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").expect("write")
    let response: string = stream.read_to_end(65536).expect("read").to_string()
    control.stop().expect("stop")
    return response.contains("\r\n\r\nlive")
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.services.add_singleton(
        type_of(SmokeGreeting), type_of(SmokeGreeting)).expect("greeting")
    espresso.add_controllers(builder).expect("controller services")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("controllers")
    espresso.map_openapi(app).expect("openapi")
    let host: espresso.TestHost = new espresso.TestHost(app)
    let response: espresso.TestResponse = host.get(
        "/api/hello/Ada").expect("controller")
    io.println("smoke controller {response.status} {response.text()}")
    io.println("smoke openapi {host.get("/openapi.json").expect("spec").text().contains("\"openapi\":\"3.1.0\"")}")
    host.close().expect("host close")

    let live_builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let live_app: espresso.WebApplication = live_builder.build().expect("live app")
    live_app.get("/", live_handler).expect("live route")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    let server: espresso.WebServer = espresso.WebServer.bind(
        live_app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let client: Thread<bool> = thread.spawn(fn() -> bool {
        return live_client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println("smoke server {client.join()} {stats.responses}")
}
