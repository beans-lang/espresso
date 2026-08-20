package main

import espresso
import std.io

fn hello(context: espresso.HttpContext) -> Result<bool> {
    let name: string = context.request.route("name").or("world")
    context.response.text(200, "OK", "Hello, {name}!")
    return ok(true)
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("build app")
    app.use(fn(context: espresso.HttpContext,
               next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        return espresso.security_headers(context, next)
    }).expect("security headers")
    app.get("/hello/\{name\}", hello).expect("map route")
    espresso.map_openapi(app).expect("map OpenAPI")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("bind server")
    io.println("Espresso listening on http://127.0.0.1:{server.port().expect("port")}")
    io.println("Try /hello/Beans or /openapi.json")
    server.run().expect("run server")
}
