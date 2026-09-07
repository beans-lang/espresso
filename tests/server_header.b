package main

// The Server header is opt-in. By default AppOptions.server_header is "", so no
// Server header is framed — like Go's net/http and Bun. Setting it to a
// non-empty value opts back in. Reverting the default to "espresso" turns the
// first line's `false` into `true`.

import espresso
import std.io

fn hello(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("ok")
}

fn host_default() -> Result<espresso.TestHost> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    // server_header left at its default on purpose.
    let app: espresso.WebApplication = builder.build()?
    app.get("/x", hello)?
    return ok(new espresso.TestHost(app))
}

fn host_optin() -> Result<espresso.TestHost> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.options.server_header = "espresso"
    let app: espresso.WebApplication = builder.build()?
    app.get("/x", hello)?
    return ok(new espresso.TestHost(app))
}

fn main() {
    let by_default: espresso.TestHost = host_default().expect("host")
    let d: espresso.TestResponse = by_default.get("/x").expect("get")
    io.println("default has-server {d.headers.has("Server")}")
    let closed_default: Result<bool> = by_default.close()

    let opted: espresso.TestHost = host_optin().expect("host")
    let o: espresso.TestResponse = opted.get("/x").expect("get")
    io.println("optin server {o.headers.get("Server").or("<none>")}")
    let closed_optin: Result<bool> = opted.close()
}
