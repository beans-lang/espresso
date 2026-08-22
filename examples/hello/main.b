package main

import espresso
import std.io

fn hello(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let name: string = context.request.route("name").or("world")
    return espresso.text("Hello, {name}!")
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("build app")
    app.use(espresso.security_headers).expect("security headers")
    app.get("/hello/\{name\}", hello).expect("map route")
    espresso.map_openapi(app).expect("map OpenAPI")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("bind server")
    io.println("Espresso listening on http://127.0.0.1:{server.port().expect("port")}")
    io.println("Try /hello/Beans or /openapi.json")
    server.run().expect("run server")
}
