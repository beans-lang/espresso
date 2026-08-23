package main

import espresso
import std.io
import std.net
import std.thread
import std.time

fn park_clients(port: int, control: espresso.ServerControl) -> int {
    var streams: List<net.TcpStream> = []
    for index: int in 0..1100 {
        match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
            ok(stream) => { streams.push(move stream) }
            err(_) => { break }
        }
    }
    let connected: int = streams.len()
    time.sleep_millis(750)
    control.stop().expect("stop")
    time.sleep_millis(100)
    for streams.len() > 0 {
        let stream: net.TcpStream = streams.pop().expect("stream")
        let ignored: Result<bool> = stream.close()
    }
    return connected
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.backlog = 2048
    options.max_connections = 2048
    options.graceful_shutdown_ms = 25
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let clients: Thread<int> = thread.spawn(fn() -> int {
        return park_clients(port, control)
    })
    let stats: espresso.ServerStats = (await server.run()).expect("run")
    let connected: int = (await clients.join_async()).expect("clients")
    io.println(
        "parked {connected > 1000} accepted {stats.accepted > 1000} peak {stats.active_peak > 1000}")
}
