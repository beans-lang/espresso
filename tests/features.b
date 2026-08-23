package main

import espresso
import std.http
import std.io

pub class GreetingService {
    pub fn init() {}
    pub fn text(name: string) -> string { return "hello {name}" }
}

@espresso.controller(route: "/api")
pub class HelloController extends espresso.Controller {
    greeter: GreetingService

    pub fn init(greeter: GreetingService) { self.greeter = greeter }

    @espresso.get(route: "/hello/\{name\}")
    pub async fn hello(@espresso.route name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text(self.greeter.text(name))
    }
}

fn validate(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let errors: espresso.ValidationErrors = new espresso.ValidationErrors()
    errors.required("name", context.request.query()?.get("name").or(""))
    errors.integer_range("age", 12, 18, 120)
    if !errors.is_valid() {
        espresso.write_validation_problem(context, errors)?
        return espresso.detached()
    }
    return espresso.no_content()
}

fn ok_handler(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("ok")
}

async fn main_app() -> Result<bool> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.services.singleton<GreetingService>()?
    let registered: int = espresso.add_controllers(builder)?
    io.println("controllers registered {registered}")
    let app: espresso.WebApplication = builder.build()?

    let cors_options: espresso.CorsOptions = new espresso.CorsOptions()
    cors_options.allowed_origins.push("https://beans.test")
    app.use(espresso.cors(cors_options)?)?
    app.use(async fn(
            context: espresso.HttpContext,
            next: async fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        return await espresso.security_headers(context, next)
    })?
    let mapped: int = espresso.map_controllers(app)?
    io.println("controllers mapped {mapped}")
    app.get_sync("/validate", validate)?
    espresso.map_openapi(app, "/openapi.json", "Beans API", "1.0")?

    let host: espresso.TestHost = new espresso.TestHost(app)
    let controller: espresso.TestResponse =
        await host.get("/api/hello/Ada")?
    io.println("controller {controller.status} {controller.text()}")
    io.println("security {controller.headers.has("X-Content-Type-Options")}")

    let bad: espresso.TestResponse = await host.get("/validate")?
    io.println("validation {bad.status} {bad.text().contains("\"errors\"")}")

    let preflight_headers: http.Headers = new http.Headers()
    preflight_headers.add("Origin", "https://beans.test")
    preflight_headers.add("Access-Control-Request-Method", "GET")
    let preflight: espresso.TestResponse = await host.send_with_headers(
        "OPTIONS", "/api/hello/Ada", preflight_headers)?
    io.println("cors {preflight.status} {preflight.headers.get("Access-Control-Allow-Origin").or("")}")

    let spec: espresso.TestResponse = await host.get("/openapi.json")?
    io.println("openapi {spec.status} {spec.text().contains("\"openapi\":\"3.1.0\"")} {spec.text().contains("/api/hello/\{name\}")}")
    host.close()?
    return ok(true)
}

async fn protected_app() -> Result<bool> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.use(espresso.api_key("X-Api-Key", "secret")?)?
    app.get_sync("/", ok_handler)?
    let host: espresso.TestHost = new espresso.TestHost(app)
    let missing: int = (await host.get("/"))?.status
    io.println("api key missing {missing}")
    let headers: http.Headers = new http.Headers()
    headers.add("X-Api-Key", "secret")
    let valid: int =
        (await host.send_with_headers("GET", "/", headers))?.status
    io.println("api key valid {valid}")
    host.close()?
    return ok(true)
}

async fn limited_app() -> Result<bool> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.use(espresso.fixed_window_rate_limit(2, 60000)?)?
    app.get_sync("/", ok_handler)?
    let host: espresso.TestHost = new espresso.TestHost(app)
    let first: int = (await host.get("/"))?.status
    let second: int = (await host.get("/"))?.status
    let third: int = (await host.get("/"))?.status
    io.println("rate {first} {second} {third}")
    host.close()?
    return ok(true)
}

async fn main() {
    (await main_app()).expect("main app")
    (await protected_app()).expect("protected app")
    (await limited_app()).expect("limited app")
}
