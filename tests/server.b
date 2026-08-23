package main

import espresso
import std.io
import std.net
import std.thread

fn hello(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("ok")
}

fn client(port: int, control: espresso.ServerControl) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            match stream.write_text(
                    "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\nHEAD /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") {
                ok(_) => {}
                err(error) => { return "write failed {error.kind}" }
            }
            let response: string = stream.read_to_end(65536).or(new Bytes(0)).to_string()
            let stopped: bool = control.stop().or(false)
            let two: bool = response.split("HTTP/1.1 200 OK").len() == 3
            let first_body: bool = response.contains("\r\n\r\nokHTTP/1.1")
            let head_empty: bool = response.ends_with("\r\n\r\n")
            return "two {two} first-body {first_body} head-empty {head_empty} stopped {stopped}"
        }
        err(error) => {
            let ignored: Result<bool> = control.stop()
            return "connect failed {error.kind}"
        }
    }
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get_sync("/hello", hello).expect("route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = (await server.run()).expect("run")
    io.println((await visitor.join_async()).expect("visitor"))
    io.println("accepted {stats.accepted} requests {stats.requests} responses {stats.responses} errors {stats.connection_errors}")
}
