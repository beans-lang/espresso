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

    @espresso.get(route: r"/{name}")
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

`BytesResult` is the one result that answers a single request. It takes its
payload by `move` and hands it to the response rather than copying it, so the
payload is gone once the result has run; build one per request. A payload
served to many requests belongs in `text`, `json_text` or `html`, whose
`string` is shared without a copy. Running one twice returns an error saying
so — it never sends an empty body.

## Model binding

Action parameters bind by annotation, compiled once at map time into
typed extractors — a request runs no reflection lookups.

```beans
@espresso.post(route: r"/{id}/notes")
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
- `@espresso.form` reads a field from an
  `application/x-www-form-urlencoded` body, with the same `default:` and
  `required: false` as `@query` — it is the query-string grammar read from
  the body, through the same parser. A body of another media type answers
  415, not an empty field set.
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

`provider.activate(type)` constructs a type that is **not** registered,
resolving each of its constructor parameters from that provider. It is
the mounting primitive a framework built on espresso needs — a page
component or a handler object gets constructor injection without every
one of them having to become a service first. The result is boxed;
downcast it with `as?`.

```beans
let mounted: reflect.Value = scope.activate(type_of(Dashboard))?
match mounted as? Dashboard {
    some(page) => { io.println(page.title()) }
    none => {}
}
```

Every constructor parameter must be borrowed and the initializer must be
public; both are reported by `activate` itself, naming the parameter.

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

`espresso.security_headers` is **for a JSON API, not for a page**. Its
`Content-Security-Policy` is `default-src 'none'; frame-ancestors 'none'`,
which is exactly right for a response nothing loads subresources from,
and wrong for anything that serves HTML: it blocks every script file,
stylesheet, image and WebSocket the page would open, and a browser
reports that as a blank page with console errors rather than as a failed
request. An application that serves pages ships its own header layer with
the `script-src`/`connect-src` its pages actually need; espresso will not
quietly loosen this one.

`espresso.constant_time_equal(left, right)` compares two strings without
stopping at the first difference — the comparison a session token, an
antiforgery token or an API key needs, since `==` leaks the length of the
shared prefix through timing. `espresso.api_key` uses it; so should
anything else in your application that compares a secret.

## Forms

`context.request.form()` parses an `application/x-www-form-urlencoded` body
into the same `QueryValues` a query string parses into, once per request. It
is the same grammar and the same parser: `+` is a space, `%xx` decodes,
repeated names stay repeated, and `a&b=2` gives `a` an empty value.

Two things differ from a query string, because a body is not a URL. A control
byte is data here, so a `<textarea>`'s `%0D%0A` decodes to a newline instead
of being refused; NUL stays refused in both. And a request whose Content-Type
is not that media type is an error of kind `unsupported_media_type`, which
answers **415** — a handler that asked for form fields and got JSON was sent
the wrong thing, and answering with an empty field set would turn that into a
silent wrong answer.

## Cookies

`context.request.cookie(name)` reads one cookie; `request.cookies()` is the
whole jar in arrival order, parsed once per request. Values are the bytes
that arrived — a cookie is opaque to RFC 6265, so espresso decodes nothing.

```beans
match context.request.cookie("sid") {
    some(token) => { io.println(token) }
    none => {}
}

let options: espresso.CookieOptions = new espresso.CookieOptions()
options.max_age_seconds = 3600
context.response.set_cookie("sid", token, options)?
```

`CookieOptions` defaults to the safe set: `Path=/`, `HttpOnly`, `Secure`,
`SameSite=Lax`, and no `Max-Age` (a session cookie). `max_age_seconds = 0`
deletes; a negative value omits the attribute. `secure` defaults to **true**,
so a plain-http development server has to turn it off on purpose — Safari
drops a `Secure` cookie from `http://localhost`, and a cookie the browser
drops is a login that silently never happens.

`set_cookie` refuses rather than serializes. A name that is not a token, a
value outside RFC 6265's `cookie-octet`, a `Path` or `Domain` carrying a
semicolon, comma, CR or LF, or `SameSite=None` without `Secure` all come back
as an error naming the cookie — before anything is written, so a value taken
from user input can never forge an attribute or splice a second header into
the response. Because nothing is encoded on the way out and nothing is decoded
on the way in, a value that `set_cookie` accepts comes back from `cookie()`
byte for byte.

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

## Streamed responses

The buffered path is the default: a handler returns an `ActionResult`, the
router executes it, and the server frames one response. `context.begin_stream`
is the second mode, for a body whose length is not known when the head has to
go out.

```beans
fn report(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let out: espresso.ResponseStream =
        context.begin_stream(200, "text/html; charset=utf-8")?
    for row: Row in rows {
        out.write_text(render(row))?
    }
    out.finish()?
    return espresso.detached()
}
```

- The head goes out at `begin_stream`, carrying `Transfer-Encoding: chunked`,
  the request's `Date`, the application's `Server` header, the content type,
  and every header the handler added through `context.response.header(...)`
  **before** the call. Headers added afterwards go nowhere.
- **The payload is never copied.** A chunk is one vectored write of its size
  line and the caller's own bytes; the CRLF that closes a chunk rides the
  front of the next chunk's size line, so a chunk of any size costs exactly
  one write. Backpressure parks the connection fiber inside that write,
  through the same loop a buffered flush uses.
- An empty `write` sends nothing: a zero-length chunk is the terminator, so it
  can never be a chunk of the body.
- A handler that returns without calling `finish()` gets the terminator
  written for it. A handler that returns an **error** after the head has gone
  out does not: the body is deliberately left unterminated and the connection
  closes, because a truncated chunked message is how HTTP says a response is
  broken and there is no status left to change.
- A `HEAD` request gets the same head and no body at all, so every chunk is
  dropped and no terminator is written.
- `begin_stream` refuses a status that cannot carry a body (1xx, 204, 304), a
  second call on the same request, a request that already armed a `Responder`,
  and a handler-supplied `Content-Length`, `Transfer-Encoding` or `Connection`
  — the last three through the same `std.http` gate every framed response
  passes. A `TestHost` request refuses too, naming the server loop it needs.
- Responses framed before the stream — pipelined requests in the same read —
  go out ahead of the streamed head, because the head joins the output queue
  rather than jumping it. `ServerStats.streamed` counts streamed responses;
  they are counted in `responses` too.

## Protocol upgrades

A client that asks to switch protocols — a WebSocket handshake, an `h2c`
upgrade, a `CONNECT` — reaches an endpoint registered with `map_upgrade`. The
handler is handed the connection itself instead of a response to fill in.

```beans
pub class Chat implements espresso.UpgradeHandler {
    pub fn init() {}

    pub fn upgrade(context: espresso.HttpContext,
                   request: http.Request,
                   move stream: net.TcpStream) -> Result<bool> {
        let room: string = context.request.route("room").or("")
        let socket: websocket.Connection =
            websocket.Connection.accept(move stream, request)?
        return socket.send_text("welcome to {room}")
    }
}

app.map_upgrade(r"/ws/{room}", new Chat())?
```

- **The middleware pipeline runs first**, exactly as it does for a request, so
  authentication, cookies, an `Origin` check and rate limiting apply to a
  handshake. A layer that answers instead of calling `next` is the answer, and
  the socket is never handed over. That matters: `SameSite` does not protect a
  handshake, so the `Origin` check is the control against cross-site WebSocket
  hijacking, and an upgrade path that skipped the pipeline would skip it.
- **Patterns are the ordinary route patterns.** Parameters and a trailing
  catch-all work and are captured into `request.route_values` before the
  handler runs. Upgrade endpoints live in their own table, so an ordinary route
  may share the path — a page and its socket at the same URL is normal — and a
  plain `GET` never reaches a handler that expects a socket.
- **`request` is the raw parsed head**, which is what `accept_websocket` needs:
  the handshake fields, the HTTP version and the method live there and not on
  `HttpContext.request`.
- **Reads on the handed-over socket park the fiber**, they do not hold the
  worker thread, so many long-lived sockets share one worker: a handler
  waiting 900 ms for its next frame is overtaken by one that arrives later and
  waits less. `std.websocket` works over it directly, with no mode to change
  first.
- **Bytes that arrive after the handshake in the same read are a 400.** They
  belong to the next protocol, this server has already consumed them, and a
  `TcpStream` cannot carry them across the hand-off — so the handshake is
  refused rather than a socket handed over whose first frames are missing.
- **A handler that panics costs one connection.** It runs behind the same fiber
  shield a request handler does; the panic is recorded server-side and the
  server keeps accepting. There is no way to answer with a status afterwards,
  because the socket is gone.
- Responses framed before the upgrade — a pipelined `GET` in the same read —
  are pushed to the client before the hand-off. `ServerStats.upgrades` counts
  the connections that were given away; they produce no `responses` entry,
  because the `101` is written by the protocol library and not by espresso.

espresso itself imports no protocol library, so a program that registers no
upgrade endpoint links no WebSocket bridge.

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
0.1.36 for `std.calendar`, which formats the `Date` header. A contained
panic reclaims its frame on 0.1.35 and later, within the platform limits
noted under *The server*.

**Beans 0.1.40 or newer is the floor.** The server frames a response
head once and sends a large body beside it with a single vectored write,
and that path calls three entry points that landed in
[beans-lang/beans#148](https://github.com/beans-lang/beans/pull/148):
`std.http.encode_response_head_append`,
`std.net.TcpStream.write_vectored`, and `write_vectored_text`. They first
ship in 0.1.40. On 0.1.39 or older an installed `beansc` stops in the
checker on `server.b` — eight errors, six of them for
`encode_response_head_append` alone — without ever reaching codegen, and
there is no compatibility path to fall back on: the borrowed-payload send
is how a large response avoids being staged in a per-connection buffer,
so the older stdlib cannot express it.

Building against a Beans checkout rather than an install works too, but
a tree-built `beansc` resolves the runtime and stdlib **relative to the
working directory**, and an installed one exports its own package's
paths — so pointing `BEANSC` at `build/beansc` is not on its own enough.
Pin the roots with it:

```sh
B=../../beans
env BEANSC=$B/build/beansc \
    BEANS_RUNTIME=$B/runtime/beans_rt.c \
    BEANS_STDLIB=$B/stdlib/std \
    BEANS_ENCODING=$B/runtime/encoding \
    BEANS_NET=$B/runtime/net \
    BEANS_LOG=$B/runtime/log \
  ./test.sh
```

`test.sh` and `rss_gate.sh` do this for you when `BEANS_ROOT` points at
the checkout: they `cd` into it first, which is what makes the relative
roots resolve.
