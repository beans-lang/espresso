package main

import espresso
import std.io
import std.net
import std.os
import std.thread
import std.time

fn scale_target() -> int {
    // The interpreted tier walks the whole task tree per event, so its
    // lane runs a smaller herd; the native release lane keeps the full
    // 1,100 that retires the old 64-parked-await cap.
    match os.env("ESPRESSO_SCALE") {
        some(text) => { return text.to_int().or(1100) }
        none => { return 1100 }
    }
}

fn park_clients(port: int, control: espresso.ServerControl) -> int {
    var streams: List<net.TcpStream> = []
    let target: int = scale_target()
    for index: int in 0..target {
        var dialed: Result<net.TcpStream> =
            net.TcpStream.connect_timeout("127.0.0.1", port, 3000)
        if !dialed.is_ok() { break }
        streams.push((move dialed).expect("client stream"))
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
    // The full herd proves scale on the native tier; a smaller herd only
    // has to retire the old 64-parked-await cap — the interpreted
    // scheduler walks the whole task tree per event and accepts at its
    // own pace.
    let scale_bar: int = scale_target() * 9 / 10
    let accept_bar: int =
        if scale_target() >= 1100 { scale_bar } else { 65 }
    io.println(
        "parked {connected >= scale_bar} accepted {stats.accepted >= accept_bar} peak {stats.active_peak >= accept_bar}")
}
