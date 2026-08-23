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
    pub async fn hello(@espresso.route name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text("Hello, {name}!")
    }
}

async fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")

    let server: espresso.WebServer = espresso.WebServer.bind(
        app, new espresso.ServerOptions()).expect("bind")
    (await server.run()).expect("run")
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

Actions may be sync or async and return `Result<espresso.ActionResult>`.
An ActionResult is a value describing the response; the router executes
it after the action returns. The implementations are `TextResult`, `JsonResult`,
`JsonTextResult`, `NoContentResult`, `StatusResult`, `ProblemResult`,
`BytesResult`, `HtmlResult`, `ViewResult` and `DetachedResult`, with
free constructors for handlers that are not controller methods:
`espresso.text(...)`, `espresso.json_text(...)`, `espresso.status(...)`,
`espresso.problem(...)`, `espresso.view(...)`, `espresso.detached()`.
`DetachedResult` is only for a response already filled by hand.

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

`espresso.Middleware` is one async method:
`async handle(context, next) -> Result<bool>`. The built-ins cover CORS
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
keep-alive and pipelining; `serve` scales over cores with
SO_REUSEPORT. `run`, `serve`, and `TestHost` request methods are async.
Each connection is a structured child of the server run. Async route
handlers are the default; `get_sync`, `post_sync`, `map_sync`, and the
other verb `_sync` forms keep small synchronous handlers on the direct
inline path. `WorkerPool.execute` runs blocking work on its fixed crew
and asynchronously returns the value. `espresso.map_openapi(app)` serves
the route table as OpenAPI 3.1.

## Configuration

`espresso.Configuration` layers defaults, files and `--key=value`
arguments; `espresso.configure_server` fills `ServerOptions` from the
`server:` section. `server:request-timeout-ms` bounds the full request
pipeline. The old `server:pending-timeout-ms` name is accepted for the
0.3 release only when the new key is absent. A present new key always wins,
including zero. On `ServerOptions`, zero leaves the new field unset; the
effective default remains 30 seconds, and any positive new value wins over
the deprecated field.

## Versioning

This is Espresso 0.3.0. It is a breaking async-v2 migration: handlers,
middleware, authorization, the request pipeline, server entry points,
and TestHost request methods are async by default. Deferred responder
and mailbox APIs are removed. It needs a Beans async-v2 compiler with
stored async callables, TaskGroup, async Event/timers/channels/threads,
and async reflection calls.
