// Every public API the README shows, compiled and run from another
// package. A README line that does not compile fails here.
package main

import espresso
import std.encoding.json
import std.http
import std.io
import std.log
import std.reflect

// ---- services and models from the README ----------------------------------

pub interface Clock {
    fn now() -> int
}

pub class SystemClock implements Clock {
    pub fn init() {}
    pub fn now() -> int { return 42 }
}

pub class Store {
    pub fn init() {}
    pub fn label() -> string { return "store" }
}

pub interface Cache {
    fn get(key: string) -> string
}

@espresso.service(lifetime: espresso.ServiceLifetime.singleton)
pub class MemoryCache implements Cache {
    pub fn init() {}
    pub fn get(key: string) -> string { return "cached:{key}" }
}

pub class Greeter {
    pub fn init() {}
}

pub class Config {
    pub fn init() {}
}

fn load_config() -> Config { return new Config() }

pub class NoteRequest {
    pub text: string
    pub fn init(move text: string) { self.text = move text }
    pub fn validate(errors: espresso.ValidationErrors) {
        errors.required("text", self.text)
    }
}

// ---- the README's controller ----------------------------------------------

@espresso.controller(route: "/hello")
pub class HelloController extends espresso.Controller {
    pub fn init() {}

    @espresso.get(route: r"/{name}")
    pub fn hello(@espresso.route name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text("Hello, {name}!")
    }
}

@espresso.controller(route: "/notes")
pub class NotesController extends espresso.Controller {
    pub fn init() {}

    @espresso.validate
    @espresso.post(route: r"/{id}")
    pub fn annotate(@espresso.route id: int,
                    @espresso.query(default: "plain") style: string,
                    @espresso.header user_agent: string,
                    @espresso.body move note: NoteRequest,
                    @espresso.inject clock: Clock) ->
        Result<espresso.ActionResult> {
        return self.ok_text(
            "note {note.text} on {id} at {clock.now()} style {style} agent {user_agent}")
    }
}

// ---- free-function results and middleware ----------------------------------

fn plain(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("plain")
}

// Activated, never registered: `activate` resolves this type's constructor
// parameters from the provider it is called on, which is how a framework
// mounts a caller-written type without first turning it into a service.
pub class Dashboard {
    clock: Clock
    store: Store

    pub fn init(clock: Clock, store: Store) {
        self.clock = clock
        self.store = store
    }

    pub fn title() -> string {
        return "{self.store.label()}@{self.clock.now()}"
    }
}

// Its initializer takes its argument by move, which `activate` cannot supply
// from a container — the refusal names the parameter rather than failing at
// the call.
pub class Moved {
    text: string
    pub fn init(move text: string) { self.text = move text }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()

    // typed registration in every lifetime, plus resolve
    builder.services.add_singleton<Clock, SystemClock>().expect("clock")
    builder.services.add_scoped<Store, Store>().expect("store")
    builder.services.transient<Greeter>().expect("greeter")
    espresso.add_singleton_factory<Config>(
        builder.services,
        fn(provider: espresso.ServiceProvider) -> Result<Config> {
            return ok(load_config())
        }).expect("factory")

    // views registered before build
    let views: espresso.Views = new espresso.Views()
    views.add("hello", "<h1>\{\{title\}\}</h1>").expect("template")
    espresso.add_views(builder, views).expect("views")

    io.println("services {espresso.add_services(builder).expect("services")}")
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")

    // both middleware forms, including a package function as a value
    app.use(espresso.security_headers).expect("security")
    let logger: log.Logger =
        espresso.console_logger("docs").expect("logger")
    app.use_middleware(new espresso.RequestLog(logger)).expect("log")

    espresso.map_controllers(app).expect("map")
    app.get("/plain", plain).expect("plain")
    app.get("/page", fn(context: espresso.HttpContext) ->
        Result<espresso.ActionResult> {
        return espresso.view_model(
            "hello", json.parse("\{\"title\":\"Docs\"\}").expect("model"))
    }).expect("page")
    espresso.map_openapi(app).expect("openapi")

    let host: espresso.TestHost = new espresso.TestHost(app)
    io.println("hello {host.get("/hello/Beans").expect("hello").text()}")

    let headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "application/json")
    headers.add("User-Agent", "docs-test")
    let note: espresso.TestResponse = host.send_with_headers(
        "POST", "/notes/9?style=fancy", headers,
        "\{\"text\":\"remember\"\}").expect("note")
    io.println("note {note.status} [{note.text()}]")
    let invalid: espresso.TestResponse = host.send_with_headers(
        "POST", "/notes/9", headers, "\{\"text\":\"\"\}").expect("bad note")
    io.println("invalid {invalid.status} {invalid.text().contains("\"errors\"")}")

    io.println("plain {host.get("/plain").expect("plain").text()}")
    let page: espresso.TestResponse = host.get("/page").expect("page")
    io.println("page {page.status} [{page.text()}]")
    io.println("openapi {host.get("/openapi.json").expect("spec").status}")

    // resolve<T> from a request scope
    let scope: espresso.ServiceProvider =
        app.services.create_scope().expect("scope")
    let store: Store = scope.resolve<Store>().expect("resolve")
    io.println("resolved {store.label()}")
    let cache: Cache = scope.resolve<Cache>().expect("cache")
    io.println("scanned {cache.get("answer")}")
    scope.close().expect("scope close")

    let scope2: espresso.ServiceProvider =
        app.services.create_scope().expect("scope2")

    // activate: a type the container never registered, constructed with its
    // constructor parameters resolved from the scope
    let mounted: reflect.Value =
        scope2.activate(type_of(Dashboard)).expect("activate")
    match mounted as? Dashboard {
        some(page) => { io.println("activated {page.title()}") }
        none => { io.println("activated WRONG TYPE") }
    }
    match scope2.activate(type_of(Moved)) {
        ok(_) => { io.println("moved-parameter accepted (wrong)") }
        err(problem) => { io.println("moved-parameter {problem.kind} {problem.msg}") }
    }
    scope2.close().expect("scope2 close")

    // constant_time_equal answers the same as ==, without an early exit
    let secrets: List<string> =
        ["", "a", "ab", "abc", "abd", "abcd", "zbc", "abc "]
    var mismatches: int = 0
    var equal_pairs: int = 0
    for left: string in secrets {
        for right: string in secrets {
            let constant: bool = espresso.constant_time_equal(left, right)
            if constant { equal_pairs += 1 }
            if constant != (left == right) { mismatches += 1 }
        }
    }
    io.println("constant-time pairs {secrets.len() * secrets.len()} equal {equal_pairs} mismatches {mismatches}")

    // validation helpers stand alone too
    let errors: espresso.ValidationErrors = new espresso.ValidationErrors()
    errors.required("name", "")
    errors.length("name", "x", 2, 8)
    errors.integer_range("age", 200, 1, 150)
    io.println("validation {errors.count()} {errors.is_valid()} {errors.at(0).code}")

    host.close().expect("close")
}
