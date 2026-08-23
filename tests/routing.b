package main

import espresso
import std.encoding.json
import std.http
import std.io
import std.net

async fn middleware(
        context: espresso.HttpContext,
        next: async fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
    context.response.header("X-Before", "yes")
    let handled: bool = await next(context)?
    context.response.header("X-After", "yes")
    return ok(handled)
}

async fn hello(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let name: string = context.request.route("name").or("missing")
    let tag_count: int = context.request.query()?.all("tag").len()
    return espresso.text_status(200, "hello {name} tags {tag_count}")
}

fn json_echo(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let input: json.Value = espresso.body_json(context.request)?
    let output: json.Value = json.Value.object()
    output.add("name", input.get("name").or(json.Value.null()))?
    return espresso.json_text_status(201, json.stringify(output)?)
}

fn broken(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return err("database password must stay hidden", "db")
}

fn served(method: string, target: string, body: string = "") -> http.ServedRequest {
    let request: http.ServedRequest = new http.ServedRequest()
    request.head.method = method
    request.head.target = target
    request.body = Bytes.from(body)
    return request
}

async fn show(app: espresso.WebApplication,
              method: string,
              target: string,
              body: string = "") -> Result<bool> {
    let context: espresso.HttpContext = await app.handle(
        served(method, target, body),
        new net.Address("127.0.0.1", 1234))?
    io.println("{method} {target} -> {context.response.status} [{context.response.body.to_string()}]")
    io.println("middleware {context.response.headers.has("X-Before") && context.response.headers.has("X-After")}")
    context.close()?
    return ok(true)
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.use(middleware).expect("middleware")
    app.get("/hello/\{name\}", hello).expect("hello")
    app.post_sync("/json", json_echo).expect("json")
    app.get_sync("/broken", broken).expect("broken")

    (await show(app, "GET", "/hello/Ada?tag=one&tag=two")).expect("get")
    (await show(app, "HEAD", "/hello/Ada")).expect("head")
    (await show(app, "OPTIONS", "/hello/Ada")).expect("options")
    (await show(app, "POST", "/hello/Ada")).expect("method")
    (await show(app, "GET", "/missing")).expect("missing")
    (await show(app, "POST", "/json", "\{\"name\":\"Beans\"\}")).expect("json")
    (await show(app, "GET", "/broken")).expect("broken")
    match await app.handle(
        served("GET", "/bad%2"),
        new net.Address("127.0.0.1", 1234)) {
        ok(context) => io.println("bad target status {context.response.status}"),
        err(error) => io.println("bad target {error.kind}"),
    }
    app.close().expect("close app")
}
