// Every public API the README shows, compiled and run from another
// package. A README line that does not compile fails here.
package main

import espresso
import std.encoding.json
import std.http
import std.io

pub class Greeter { pub fn init() {} }

struct Message { message: string }

fn console_sink(record: espresso.LogRecord) {
    espresso.json_console_log(record)
}

fn json_message(context: espresso.HttpContext) -> Result<bool> {
    let payload: Message = Message { message: "Hello, World!" }
    return espresso.write_json_text(
        context.response, 200, "OK", json.encode(payload)?)
}

fn dom_handler(context: espresso.HttpContext) -> Result<bool> {
    let reply: json.Value = json.Value.object()
    reply.add("ok", json.Value.from_bool(true))?
    return espresso.write_json(context.response, 201, "Created", reply)
}

fn validate(context: espresso.HttpContext) -> Result<bool> {
    let errors: espresso.ValidationErrors = new espresso.ValidationErrors()
    let name: string = context.request.query()?.get("name").or("")
    errors.required("name", name)
    errors.length("name", name, 1, 64)
    errors.integer_range("age", 30, 18, 120)
    errors.add("email", "email is already taken", "conflict")
    io.println("validation count {errors.count()} valid {errors.is_valid()} first {errors.at(0).code}")
    if !errors.is_valid() {
        return espresso.write_validation_problem(context, errors)
    }
    context.response.no_content()
    return ok(true)
}

fn request_members(context: espresso.HttpContext) -> Result<bool> {
    let decoded: string = context.request.decoded_path()?
    let segments: int = context.request.segment_count()?
    let first: string = if segments > 0 {
        context.request.segment_at(0)?
    } else { "" }
    let query: espresso.QueryValues = context.request.query()?
    let all: List<string> = query.all("tag")
    io.println("path {decoded} segments {segments} first {first} tags {all.len()} q {query.count()} head_only {context.head_only}")
    context.response.header("Cache-Control", "no-store")
    context.response.text_body(200, "OK", "<b>hi</b>", "text/html")
    return ok(true)
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.options.detailed_errors = true
    builder.options.server_header = "espresso"
    builder.services.add_singleton(type_of(Greeter), type_of(Greeter))
        .expect("greeter")
    let app: espresso.WebApplication = builder.build().expect("app")

    app.use(fn(context: espresso.HttpContext,
               next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        context.response.header("X-Request-Id", context.trace_id())
        return next(context)
    }).expect("trace middleware")
    app.use(fn(context: espresso.HttpContext,
               next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        return espresso.security_headers(context, next)
    }).expect("security")

    let cors_options: espresso.CorsOptions = new espresso.CorsOptions()
    cors_options.allowed_origins.push("https://app.example.com")
    cors_options.allow_credentials = true
    app.use(espresso.cors(cors_options).expect("cors")).expect("use cors")
    app.use(espresso.fixed_window_rate_limit(100000, 60000).expect("limit"))
        .expect("use limit")

    let logger: espresso.Logger = new espresso.Logger()
    logger.configure(espresso.LogLevel.warn, console_sink)
    app.use(espresso.request_logging(logger)).expect("logging")

    app.get("/json", json_message).expect("json")
    app.post("/dom", dom_handler).expect("dom")
    app.get("/validate", validate).expect("validate")
    app.get("/files/\{*rest\}", request_members).expect("catch all")
    app.map("REPORT", "/report", json_message).expect("custom method")
    espresso.map_openapi(app, "/openapi.json", "Doc Check", "0.1.0")
        .expect("openapi")

    let host: espresso.TestHost = new espresso.TestHost(app)
    io.println("json {host.get("/json").expect("json").text()}")
    io.println("dom {host.post("/dom", "\{\}").expect("dom").status}")
    let bad: espresso.TestResponse = host.get("/validate").expect("validate")
    io.println("validate {bad.status} problem {bad.text().contains("\"errors\"")}")
    let deep: espresso.TestResponse =
        host.get("/files/a/b/c?tag=x&tag=y").expect("files")
    io.println("files {deep.status} {deep.text()}")
    io.println("404 {host.get("/nope").expect("404").status}")
    io.println("405 {host.post("/json", "").expect("405").status}")
    let headers: http.Headers = new http.Headers()
    headers.add("Origin", "https://app.example.com")
    headers.add("Access-Control-Request-Method", "GET")
    io.println("preflight {host.send_with_headers("OPTIONS", "/json", headers).expect("pre").status}")
    io.println("spec {host.get("/openapi.json").expect("spec").status}")
    let logged: espresso.TestResponse = host.get("/json").expect("trace")
    io.println("trace {logged.trace_id != ""} server {logged.headers.has("Server")}")
    host.close().expect("close")

    let config: espresso.Configuration = new espresso.Configuration()
    config.set("server:port", "8080").expect("set")
    config.add_arguments(["--server:port=0"]).expect("args")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    espresso.configure_server(config, options).expect("configure")
    io.println("config port {options.port} host {options.host}")
    io.println("workers {espresso.recommended_workers()}")
}
