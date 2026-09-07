# Espresso

A web framework for [Beans](https://github.com/beans-lang/beans) in the
shape of ASP.NET Core: annotated controllers with constructor injection,
model binding, action results, filters, middleware, server-side views,
and a fast server underneath. Everything below compiles and runs from
`tests/docs.b` — a README line that does not compile fails the build.

```beans
import espresso

@espresso.controller(route: "/hello")
pub class HelloController extends espresso.Controller {
    pub fn init() {}

    @espresso.get(route: "/\{name\}")
    pub fn hello(@espresso.route name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text("Hello, {name}!")
    }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")

    let server: espresso.WebServer = espresso.WebServer.bind(
        app, new espresso.ServerOptions()).expect("bind")
    server.run().expect("run")
}
```

For a real application — stores behind interfaces, auth policies,
validation, a rendered dashboard — read `examples/taskhub/main.b`.

## Controllers

A controller is a class marked `@espresso.controller(route: prefix)`.
Every public method with a verb annotation — `@espresso.get`,
`@espresso.post`, `@espresso.put`, `@espresso.patch`,
`@espresso.delete` — becomes an endpoint under that prefix. Controllers
are scoped services: one instance per request, dependencies arriving
through the constructor from the same container as everything else.

Deriving from `espresso.Controller` is optional but earns the result
helpers — `self.ok(json)`, `self.ok_text(text)`, `self.created(json)`,
`self.no_content()`, `self.not_found()`, `self.bad_request(detail)`,
`self.problem(status, title, detail)` — and `self.context()` for the
rare action that wants the raw request. A class with action annotations
and no base class is still a controller.

Actions return `Result<espresso.ActionResult>`. An ActionResult is a
value describing the response; the router executes it after the action
returns. The implementations are `TextResult`, `JsonResult`,
`JsonTextResult`, `NoContentResult`, `StatusResult`, `ProblemResult`,
`BytesResult`, `HtmlResult`, `ViewResult` and `DetachedResult`, with
free constructors for handlers that are not controller methods:
`espresso.text(...)`, `espresso.json_text(...)`, `espresso.status(...)`,
`espresso.problem(...)`, `espresso.view(...)`, `espresso.detached()`.

## Model binding

Action parameters bind by annotation, compiled once at map time into
typed extractors — a request runs no reflection lookups.

```beans
@espresso.post(route: "/\{id\}/notes")
pub fn annotate(@espresso.route id: int,
                @espresso.query(default: "plain") style: string,
                @espresso.header user_agent: string,
                @espresso.body move note: NoteRequest,
                @espresso.inject clock: Clock) ->
    Result<espresso.ActionResult> {
    return self.ok_text("note {note.text} on {id} at {clock.now()}")
}
```

- `@espresso.route` reads a route value (`{id}`) as `int`, `float`,
  `bool` or `string`. A value that does not parse answers 400.
- `@espresso.query` reads a query field, with `default:` for optional
  fields and `required: false` for bind-the-zero-value optionality.
- `@espresso.header` reads a header as a string; underscores in the
  parameter name become dashes, so `user_agent` reads `user-agent`.
- `@espresso.body` parses the JSON body and constructs the parameter
  through its type's initializer, fields matched by name, nested
  objects and scalar lists included. Malformed bodies answer 400 with
  a problem+json explanation, never a 500.
- `@espresso.inject` resolves the parameter from the request's service
  scope.
- A parameter typed `espresso.HttpContext` binds with no annotation.

## Filters

Filters compose per action at map time. The action's own annotations
win over the controller's.

- `@espresso.auth(policy: "admin")` calls the registered
  `espresso.Authorizer` service and answers 403 when it declines.
- `@espresso.validate` runs each bound body's
  `validate(errors: espresso.ValidationErrors)` method and answers 400
  with the collected field problems when any were recorded.
- `@espresso.limit(rpm: 120)` fixed-window rate limit per worker;
  answers 429 with a `Retry-After` header.

## Services

Registration is generic and typed; lifetimes are transient, scoped and
singleton. `resolve` is a method on any provider or scope.

```beans
builder.services.add_singleton<Clock, SystemClock>()?
builder.services.add_scoped<Store, SqlStore>()?
builder.services.transient<Greeter>()?
let store: Store = context.services.resolve<Store>()?
```

The runtime-typed `add(service, implementation, lifetime)` stays as the
escape hatch for types only known at runtime — the controller scanner
itself uses it — and factories cover values built by hand:

```beans
espresso.add_singleton_factory<Config>(
    builder.services,
    fn(provider: espresso.ServiceProvider) -> Result<Config> {
        return ok(load_config())
    })?
```

Registration can also be discovered. `@espresso.service` marks a class;
`espresso.add_services(builder)` scans and registers it as itself and as
each interface it directly implements, forwarded so one scope shares one
instance across all of its names:

```beans
@espresso.service(lifetime: espresso.ServiceLifetime.singleton)
pub class SystemClock implements Clock {
    pub fn init() {}
    pub fn now() -> int { return 0 }
}

espresso.add_services(builder)?
```

The lifetime is the `ServiceLifetime` enum and defaults to scoped. Two
`@service` classes claiming the same service type is a scan-time error —
drop the annotation from one and register your choice explicitly. A
language `singleton class` cannot be container-activated and is refused
at scan time; register its `.instance` through a factory instead.
`@controller` classes are already scoped services and refuse a second
`@service` marking.

Scope discipline is validated: resolving a scoped service from the root
provider, capturing a scoped service inside a singleton, and dependency
cycles are all errors, not surprises.

## Middleware

A middleware is a function or an object; both share one pipeline in
registration order.

```beans
app.use(espresso.security_headers)?
app.use_middleware(new espresso.RequestLog(logger))?
```

`espresso.Middleware` is one method:
`handle(context, next) -> Result<bool>`. The built-ins cover CORS
(`espresso.cors`), security headers, API keys (`espresso.api_key`) and
a whole-app rate limit (`espresso.fixed_window_rate_limit`).

## Logging

Espresso logs on `std.log`. `espresso.console_logger(name)` builds the
common case; any `log.Logger` — files, rotation, JSON, an ExportSink —
drops in. `espresso.RequestLog` logs one line per request with status,
duration and trace id. There is deliberately no callback sink: user
code never runs inside the logger.

## Views

`espresso.view(name, model)` renders a registered template as HTML.
The model is typed at the call site — anything `json.encode` accepts —
and the template language is small: `{{name}}` inserts escaped,
`{{{name}}}` raw, `{{#items}}...{{/items}}` repeats over arrays or
descends into objects, `{{^items}}...{{/items}}` renders when empty.

```beans
let views: espresso.Views = new espresso.Views()
views.add("hello", "<h1>\{\{title\}\}</h1>")?
espresso.add_views(builder, views)?
```

## The server

`espresso.WebServer.bind(app, options)` serves plain HTTP/1.1 with
keep-alive and pipelining; `serve_workers` scales over cores by
accepting on one listener and dealing each connection to a worker.
It does not use SO_REUSEPORT, and on macOS that is why it works:
Darwin's SO_REUSEPORT does not balance — the last socket to bind
receives every connection — so a shared-port design there runs on
one core no matter how many workers it starts.

A connection frames pipelined responses into one output queue and sends
them together, up to `ServerOptions.max_queued_output_bytes` (64 KiB) at a
time; reaching that bound sends what is queued before the next response is
framed, so a burst of pipelined requests cannot turn into an unbounded
per-connection buffer, and a queue that did outgrow the bound hands its
memory back rather than keeping it for the life of the connection.

`context.respond_later()` hands a move-only `Responder` to any thread
for deferred responses — return `espresso.detached()` from the handler.
`espresso.TestHost` runs the full pipeline in memory for tests, and
`espresso.map_openapi(app)` serves the route table as OpenAPI 3.1.

Every response carries a `Date` header (RFC 9110 IMF-fixdate, GMT),
formatted once per wall-clock second and reused; a handler that sets its
own `Date` keeps it.

A panicking handler costs one request, not the connection: the request
runs behind a fiber shield, the panic becomes that request's 500, and the
connection closes. On Beans 0.1.35 and later the panicking frame also
**unwinds** — its `defer`s run and its locals' `deinit`s run — so buffers,
files, locks and the request's DI scope are released rather than leaked.
That unwind is a native-backend feature and today it covers ELF and Mach-O
on x86-64 and arm64. **A Windows build has no unwind yet**: containment
still holds and the server keeps serving, but a contained panic abandons
its frame and leaks what the request held, so a Windows deployment should
treat a panicking handler as a resource leak until a COFF unwind lands in
the compiler.

## Configuration

`espresso.Configuration` layers defaults, files and `--key=value`
arguments; `espresso.configure_server` fills `ServerOptions` from the
`server:` section.

## Versioning

This is Espresso 0.2.0, one breaking release over 0.1: handlers return
`ActionResult` instead of writing the response, registration is
generic instead of `type_of` pairs, `ServiceKey` is gone, logging moved
to `std.log`, and the binding and filter annotations are new. It needs
Beans 0.1.29 for explicit type arguments, package function values, and
the reflection speed that makes controllers a first-class path, and
**Beans 0.1.36 or newer** to build at all: the `Date` header is formatted
with `std.calendar`, which first ships in 0.1.36. A contained panic
reclaims its frame on 0.1.35 and later, within the platform limits noted
under *The server*.
