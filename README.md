# Espresso

An OOP web API framework for [Beans](https://github.com/beans-lang/beans).

Its shape is close to ASP.NET Core: a builder, constructor-injected services,
middleware, routing, controllers, per-request scopes, layered configuration,
structured logs, validation, security helpers, OpenAPI, and an in-memory test
host.

The server underneath is a level-triggered non-blocking HTTP/1.1 event loop
built on `std.poll`, `std.http`, and `std.net`, with bounded input and output
buffers. The same source builds for macOS, Linux, and Windows.

---

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [How a request flows](#how-a-request-flows)
- [Routing](#routing)
- [HttpContext](#httpcontext)
- [Middleware](#middleware)
- [Dependency injection](#dependency-injection)
- [Controllers](#controllers)
- [JSON](#json)
- [Validation](#validation)
- [Configuration](#configuration)
- [Logging](#logging)
- [Security](#security)
- [OpenAPI](#openapi)
- [Testing](#testing)
- [Blocking work](#blocking-work)
- [Workers](#workers)
- [Running a server](#running-a-server)
- [ServerOptions reference](#serveroptions-reference)
- [Errors](#errors)
- [Performance](#performance)
- [Building and shipping](#building-and-shipping)
- [Development](#development)
- [Current boundary](#current-boundary)
- [License](#license)

---

## Requirements

**Beans 0.1.28 or newer.** Espresso uses `TcpStream.set_nodelay`,
`TcpListener.try_accept`, `http.Headers.clear`,
`http.RequestParser.feed_range_into` / `finish_into` /`recycle`, and
`poll.Poller.wait_into`. On 0.1.27 the build fails with unknown-method errors.

No other dependency. Everything else is the Beans standard library.

## Install

Add the requirement to your `beans.pot`:

```beans-pot
module myapi
kind application
require github.com/beans-lang/espresso v0.1.0
```

or from the project root:

```sh
beansc pot add beans-lang/espresso v0.1.0
```

Then import it. The Git path is the import path, and the binding is the
package's declared name, `espresso`:

```beans
import github.com/beans-lang/espresso
```

Every snippet below writes `import espresso` for brevity — that is the form the
in-repo examples use, because there the module root *is* espresso. In your own
project use the full Git path, or alias it once per file:

```beans
import github.com/beans-lang/espresso as espresso
```

## Quick start

```beans
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
    app.get("/hello/\{name\}", hello).expect("map route")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("bind server")
    io.println("listening on http://127.0.0.1:{server.port().expect("port")}")
    server.run().expect("run server")
}
```

```sh
beansc run examples/hello/main.b
curl http://127.0.0.1:8080/hello/Beans
```

Three objects carry the whole model:

| Object | Life | Job |
| --- | --- | --- |
| `WebApplicationBuilder` | Before start | Collects services and `AppOptions`. |
| `WebApplication` | Whole process | Owns routes, middleware, and the root service provider. |
| `WebServer` | Whole process | Owns the listener, the poller, and the event loop. |

`builder.build()` freezes the service registrations and returns the
application. Calling it twice is an error.

`AppOptions` has two fields:

- `detailed_errors: bool = false` — when true, a failed handler's own message
  reaches the client. Leave it off in production.
- `server_header: string = "espresso"` — stamped on every response unless the
  handler already set `Server`. Set it to `""` to send none.

## How a request flows

```
accept → parse head → begin request → open scope
       → middleware (outer to inner)
       → router.dispatch → handler
       → close scope → write response
```

1. The loop parses one request head, then streams the body into the request's
   buffer under `max_body_bytes`.
2. The application opens a DI scope for the request — but only if any services
   are registered. No registrations means no scope work at all.
3. Middleware runs outer-to-inner, then the router picks an endpoint.
4. If nothing wrote a response, the server sends `204 No Content`.
5. The scope closes, disposing scoped services in reverse creation order.

**Reuse:** the server keeps one `HttpContext`, one `HttpRequest`, and one
`HttpResponse` per *connection* and resets them between requests. Anything that
must outlive the handler has to be copied out. This is what keeps the steady
state allocation-free.

## Routing

```beans
app.get("/users", list_users)?
app.post("/users", create_user)?
app.put("/users/\{id\}", replace_user)?
app.patch("/users/\{id\}", patch_user)?
app.delete("/users/\{id\}", delete_user)?
app.map("REPORT", "/users/\{id\}/report", report)?   // any method
```

Pattern syntax:

| Form | Meaning |
| --- | --- |
| `/users` | Literal segment. Percent-escapes in the pattern are decoded once, at map time. |
| `/users/{id}` | One segment, captured as `id`. |
| `/files/{*rest}` | Catch-all. Must be the last segment. Captures the remaining path, slashes included. |

Rules the router enforces at `map` time, not at request time:

- A pattern must start with `/` and must not contain `?` or `#`.
- Braces wrap a whole segment — `/a{id}b` is rejected.
- A parameter needs a name, and a name cannot repeat inside one pattern.
- Two routes with the same method and the same literal/parameter *shape*
  conflict, and the second `map` returns a `route_conflict` error.

**Precedence** is by score, most specific first: a literal segment scores 100,
a parameter 10, a catch-all 1. So `/users/me` beats `/users/{id}`, which beats
`/files/{*rest}`.

**Method handling:**

- `HEAD` falls back to the `GET` route; the server writes the headers and drops
  the body.
- `OPTIONS` with no explicit route gets `204` plus an `Allow` header built from
  every route whose path matches.
- A path that matches but a method that does not gets `405` plus `Allow`.
- No path match gets `404`.

**The fast path:** a request whose raw path contains no `%` or `#` and whose
route is fully literal is answered straight out of a per-method hash map — no
splitting, no decoding, no allocation. Parameter routes take the scan path,
which is where `segment` decoding happens.

Reading captures:

```beans
let id: string = context.request.route("id").or("")      // Option<string>
```

## HttpContext

`context.request` — `HttpRequest`:

| Member | Notes |
| --- | --- |
| `method`, `target` | As received. `target` is the origin-form target, query included. |
| `path` | The target up to `?`. **Raw and undecoded.** |
| `decoded_path()` | `Result<string>` — decoded and canonically rebuilt. |
| `segment_count()`, `segment_at(i)` | Decoded path segments. |
| `query()` | `Result<QueryValues>` — parsed on first call, cached for the request. |
| `route(name)` | `Option<string>` — a captured route value. |
| `headers` | `http.Headers`. |
| `body` | `Bytes`, filled before the handler runs. |
| `trailer_fields` | Chunked trailers, when any arrived. |
| `remote` | `net.Address` of the peer. |
| `keep_alive` | What the request asked for. |

`QueryValues` keeps fields in arrival order and keeps repeats:
`count()`, `get(name) -> Option<string>`, `all(name) -> List<string>`,
`name_at(i)`, `value_at(i)`.

`context.response` — `HttpResponse`:

```beans
context.response.text(200, "OK", "hello")                       // text/plain
context.response.text_body(200, "OK", body, "text/html")        // copies into the reused buffer
context.response.bytes(200, "OK", move payload, "image/png")    // hands over a Bytes
context.response.no_content()                                   // 204
context.response.header("Cache-Control", "no-store")
```

`text_body` is the allocation-free form: it copies into the buffer the
connection already owns. `bytes` takes ownership of a `Bytes` you built.

The server owns `Content-Length` and `Connection` — do not set them. It also
stamps `Server` from `AppOptions.server_header`.

Other context members:

- `context.services` — the `ServiceProvider` for this request's scope.
- `context.trace_id()` — a stable per-request id, formatted on first use, and
  echoed in every problem response.
- `context.head_only` — true when the request was `HEAD`.
- `context.respond_later()` — see [Blocking work](#blocking-work).

## Middleware

A middleware is a function of `(HttpContext, next) -> Result<bool>`. They run
in registration order, outermost first.

```beans
app.use(fn(context: espresso.HttpContext,
           next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
    context.response.header("X-Request-Id", context.trace_id())
    return next(context)
})?
```

Short-circuit by writing a response and returning without calling `next`:

```beans
app.use(fn(context: espresso.HttpContext,
           next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
    if !context.request.headers.has("Authorization") {
        context.response.text(401, "Unauthorized", "who are you")
        return ok(true)
    }
    return next(context)
})?
```

Middleware that ships in the box: `security_headers`, `cors(options)`,
`api_key(header, secret)`, `fixed_window_rate_limit(...)`,
`request_logging(logger)`. Some are plain functions and some are builders that
return one — see [Security](#security) and [Logging](#logging).

Routes and middleware can only be added before the application is closed.

## Dependency injection

Register against the builder, before `build()`. Constructor parameters are
resolved by type.

```beans
builder.services.add_singleton(type_of(Clock), type_of(SystemClock))?
builder.services.add_scoped(type_of(Store), type_of(SqlStore))?
builder.services.add_transient(type_of(Greeter), type_of(Greeter))?
```

| Lifetime | Created | Disposed |
| --- | --- | --- |
| `transient` | Every resolve. | Never cached. |
| `scoped` | Once per request scope. | At the end of the request, reverse creation order. |
| `singleton` | Once per provider. | At `app.close()`, reverse creation order. |

The implementation type must be assignable to the service type, checked at
registration. Interfaces work: `add_singleton(type_of(Clock), type_of(FixedClock))`.

**Factories** when a constructor is not enough. `T` is inferred from the
factory's declared result type:

```beans
fn make_pool(provider: espresso.ServiceProvider) -> Result<ConnectionPool> {
    return ok(new ConnectionPool("postgres://..."))
}

espresso.add_singleton_factory(builder.services, make_pool)?
// also: add_scoped_factory, add_transient_factory, add_factory(services, lifetime, fn)
```

**Resolving.** Beans does not infer a generic argument from a result type, so
resolution carries the type in a small witness value:

```beans
let store: Store = espresso.service(
    context.services, new espresso.ServiceKey<Store>())?
```

**What Espresso refuses**, and when:

- Resolving a service that was never registered.
- A dependency cycle — reported with the chain.
- Resolving a scoped service from the root provider.
- A singleton whose constructor takes a scoped service (captive dependency).

The last two are on by default; `build_provider(validate_scopes: false)` turns
them off if you know what you are doing.

## Controllers

Call `add_controllers` before `build()` to register every annotated controller
class as a scoped service, then `map_controllers` after `build()` to map their
actions. Both return how many they found.

```beans
@espresso.controller(route: "/api")
pub class UsersController {
    store: UserStore

    pub fn init(store: UserStore) { self.store = store }

    @espresso.http_get(route: "/users/\{id\}")
    pub fn get(context: espresso.HttpContext) -> Result<bool> {
        let id: string = context.request.route("id").or("")
        context.response.text(200, "OK", self.store.name_of(id))
        return ok(true)
    }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.services.add_singleton(type_of(UserStore), type_of(UserStore))
        .expect("store")
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")
    // ...
}
```

Annotations: `@espresso.controller(route: ...)` on the class, and
`@espresso.http_get`, `http_post`, `http_put`, `http_patch`, `http_delete`
— each taking `route:` — on the actions.

An action must be `pub`, synchronous, take exactly one `HttpContext`, and
return `Result<bool>`. Anything else is a mapping-time error, not a runtime
surprise. The controller instance is resolved from the request scope, so
constructor injection works and scoped dependencies are per request.

Under the hood this is `std.reflect`; the controller route is the class
annotation's `route` joined with the action's.

## JSON

For the DOM:

```beans
import std.encoding.json

fn create(context: espresso.HttpContext) -> Result<bool> {
    let body: json.Value = espresso.body_json(context.request)?
    let reply: json.Value = json.Value.object()
    reply.add("ok", json.Value.from_bool(true))?
    return espresso.write_json(context.response, 201, "Created", reply)
}
```

For typed structs — faster, and the path the benchmarks use — go through the
standard library encoder and hand Espresso the encoded text:

```beans
struct Message { message: string }

fn json_message(context: espresso.HttpContext) -> Result<bool> {
    let payload: Message = Message { message: "Hello, World!" }
    return espresso.write_json_text(
        context.response, 200, "OK", json.encode(payload)?)
}
```

Decoding a body into a struct is `json.decode_bytes(context.request.body)`.

All three write `application/json; charset=utf-8`.

## Validation

```beans
let errors: espresso.ValidationErrors = new espresso.ValidationErrors()
errors.required("name", context.request.query()?.get("name").or(""))
errors.length("name", name, 1, 64)
errors.integer_range("age", age, 18, 120)
errors.add("email", "email is already taken", "conflict")   // custom

if !errors.is_valid() {
    return espresso.write_validation_problem(context, errors)
}
```

`write_validation_problem` sends `400` as
`application/problem+json; charset=utf-8`:

```json
{
  "status": 400,
  "title": "Validation Failed",
  "traceId": "espresso-17",
  "errors": [{ "field": "name", "message": "name is required", "code": "required" }]
}
```

Also on `ValidationErrors`: `count()`, `at(index)`, `is_valid()`.

## Configuration

`Configuration` is a flat, case-insensitive string map with layered sources.
Later sources replace earlier ones.

```beans
let config: espresso.Configuration = new espresso.Configuration()
config.set("server:port", "8080")?
config.add_environment(["server:host", "server:port"])?   // ESPRESSO_SERVER__HOST, ...
config.add_arguments(os.args())?                          // --server:port=9000 or --server:port 9000

let options: espresso.ServerOptions = new espresso.ServerOptions()
espresso.configure_server(config, options)?
```

- `add_environment(names, prefix = "ESPRESSO_")` reads a **known** list of
  names. `:` maps to `__` and the name is upper-cased, so `server:host` reads
  `ESPRESSO_SERVER__HOST`. It never scans the whole environment.
- `add_arguments` accepts `--key=value` and `--key value`. A `--key` with no
  value is an error.

Readers: `get(name) -> Option<string>`, `require(name) -> Result<string>`,
`integer(name, fallback)`, `boolean(name, fallback)`. `boolean` takes
`true/1/yes/on` and `false/0/no/off`, and errors on anything else.

`configure_server` applies these keys and then validates:
`server:host`, `server:port`, `server:backlog`, `server:max-connections`,
`server:idle-timeout-ms`, `server:graceful-shutdown-ms`, `server:max-body-bytes`.

## Logging

```beans
let logger: espresso.Logger = new espresso.Logger()
app.use(espresso.request_logging(logger))?

logger.info("startup", "ready")
logger.warn("cache", "miss rate high", context.trace_id())
logger.error("db", "connect failed", context.trace_id())
```

Levels: `trace`, `debug`, `info`, `warn`, `error`, `none`. A new `Logger`
starts at `info` and writes one JSON object per line to standard output.

To change the level or send records elsewhere, call `configure`. A sink is any
`fn(LogRecord)`. Beans cannot pass another package's function as a value, so
write the sink in your own package — including when all you want is the
built-in one:

```beans
fn console_sink(record: espresso.LogRecord) {
    espresso.json_console_log(record)
}

logger.configure(espresso.LogLevel.warn, console_sink)
```

Records carry `level`, `event`, `message`, `trace_id`, `monotonic_nanos`, and
free-form fields:

```beans
let record: espresso.LogRecord = new espresso.LogRecord(
    espresso.LogLevel.info, "order.paid", "payment captured", context.trace_id())
record.field("orderId", id).field("amountCents", "{cents}")
logger.write(record)
```

`request_logging` wraps the rest of the pipeline and logs one `http.request`
record per request with `status` and `durationNanos`, at `info` when the
pipeline succeeded and `error` when it failed.

## Security

```beans
app.use(fn(context: espresso.HttpContext,
           next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
    return espresso.security_headers(context, next)
})?
```

`security_headers` adds `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, and
`Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`.

**CORS.** Strict by default: an `Origin` that is not allowed gets `403`, not a
silent pass.

```beans
let cors_options: espresso.CorsOptions = new espresso.CorsOptions()
cors_options.allowed_origins.push("https://app.example.com")
cors_options.allow_credentials = true
app.use(espresso.cors(cors_options)?)?
```

Defaults: all common methods, `Content-Type` and `Authorization` headers,
`max_age_seconds = 600`, credentials off. `"*"` combined with
`allow_credentials` is refused at build time. Preflights answer `204` with the
allow headers; other requests get `Access-Control-Allow-Origin` and
`Vary: Origin` and continue.

**API key.** Compares in constant time — no early exit on the first wrong byte:

```beans
app.use(espresso.api_key("X-Api-Key", secret)?)?
```

A miss gets `401` with `WWW-Authenticate: ApiKey`.

**Rate limit.** Fixed window, keyed on the peer host, with a bounded client
table:

```beans
app.use(espresso.fixed_window_rate_limit(100, 60000)?)?          // 100 / minute
app.use(espresso.fixed_window_rate_limit(100, 60000, 4096)?)?    // smaller table
```

Over the limit gets `429` with `Retry-After`. `max_clients` defaults to 65536
and caps memory; it is per application, so under `serve` each worker keeps its
own.

## OpenAPI

```beans
espresso.map_openapi(app)?                                      // GET /openapi.json
espresso.map_openapi(app, "/spec.json", "Orders API", "2.1")?
let text: string = espresso.openapi_json(app, "Orders API", "2.1")?
```

The document is OpenAPI 3.1 and is generated **once, at map time**, from the
route table as it stands. Map it last. Path parameters are declared as required
string parameters; bodies and response schemas are not inferred.

## Testing

`TestHost` runs the real pipeline — middleware, router, handler, scopes — with
no socket:

```beans
let host: espresso.TestHost = new espresso.TestHost(app)

let reply: espresso.TestResponse = host.get("/hello/Beans")?
io.println("{reply.status} {reply.text()}")

let created: espresso.TestResponse = host.post("/users", "\{\"name\":\"ada\"\}")?

let headers: http.Headers = new http.Headers()
headers.add("X-Api-Key", "secret")
let authed: espresso.TestResponse = host.send_with_headers("GET", "/", headers)?

host.close()?
```

`TestResponse` is a stable copy — `status`, `reason`, `headers`, `body`,
`trace_id`, and `text()` — so it survives past the context that produced it.
`host.close()` closes the application and its singletons.

Deferred handlers need the real loop, so they are not answerable through
`TestHost`.

## Blocking work

Handlers run on the event loop. Blocking it blocks every other connection on
that loop. Work that waits — a database call, an outside service, a long
computation — goes to a `WorkerPool`, and the request finishes later through a
`Responder`.

```beans
let pool: espresso.WorkerPool = espresso.WorkerPool.start(4).expect("pool")

app.get("/report", fn(context: espresso.HttpContext) -> Result<bool> {
    let responder: espresso.Responder = context.respond_later()?
    pool.submit(fn() move(responder) {
        let report: string = build_report_slowly()
        let sent: Result<bool> = responder.json(200, "OK", report)
    })?
    return ok(true)
}).expect("route")
```

`respond_later()` marks the request deferred and returns a move-only `Send`
handle. What that buys you:

- The connection **stops reading** until the responder answers, so pipelined
  requests behind it still come back in order.
- Exactly one sending call wins. A second call, or one that arrives after the
  connection is gone, is dropped instead of corrupting the stream.
- A deferred request nobody answers gets `503` after
  `ServerOptions.pending_timeout_ms` (default 30 s), and the connection closes.
- A graceful stop waits for in-flight deferred responses.

`Responder` has `text`, `json`, `bytes`, and `header(name, value)`. Content-Length
and Connection stay with the server, same as `HttpResponse`.

`WorkerPool` is plain threads over one bounded channel:

```beans
espresso.WorkerPool.start(workers, queue_depth = 256)
pool.submit(move job)   // blocks when queue_depth jobs already wait — backpressure, not loss
pool.close()            // lets queued jobs finish, then joins the crew
```

The pool handle is loop-local even though its jobs are `Send`. With
`espresso.serve`, build one pool per worker inside that worker's factory.

## Workers

`espresso.serve` takes one application factory per worker and blocks until they
return.

```beans
fn build_app() -> Result<espresso.WebApplication> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build()?
    app.get("/json", json_message)?
    return ok(app)
}

fn main() {
    var factories: List<send fn() -> Result<espresso.WebApplication>> = []
    for index: int in 0..espresso.recommended_workers() {
        factories.push(build_app)
    }
    espresso.serve(new espresso.ServerOptions(), move factories)
        .expect("serve")
}
```

- **One factory** serves from the calling thread. No extra threads, no handoff.
- **More than one**: the calling thread owns the listening socket and deals
  each accepted connection round-robin to the workers. Every worker runs its
  own event loop, application, service graph, and poller. Workers share
  nothing, so nothing contends.

`recommended_workers()` returns **1**. That is measured, not conservative: on
macOS a single loop matched a four-process Bun lane's throughput at lower CPU
per request, because the kernel serializes accepts through one listener and
extra loops mostly buy contention. Give more workers to CPU-heavy handlers that
saturate the one loop — and route blocking work through a `WorkerPool` either
way, which is what keeps a single loop honest.

Each worker gets its own slice of the connection budget; the per-worker limits
are derived from the `ServerOptions` you pass in.

## Running a server

```beans
let server: espresso.WebServer = espresso.WebServer.bind(app, options)?
let control: espresso.ServerControl = server.control()
let port: int = server.port()?          // useful with port 0
let stats: espresso.ServerStats = server.run()?
```

`run()` blocks until a stop is requested and the drain finishes, then returns
counts for the run: `accepted`, `rejected`, `requests`, `responses`,
`connection_errors`, `active_peak`.

`ServerControl` is a copyable struct, safe to hand to another thread:

```beans
control.stop()          // wakes the poller and starts a graceful shutdown
control.is_stopping()
```

A graceful stop closes the listener, lets in-flight requests and deferred
responses finish, flushes pending writes, and gives up after
`graceful_shutdown_ms`. `server.close()` is the hard version — it drops
resources without draining.

`WebServer.adopt(app, options, move listener)` wraps a listener you already
bound; that is how `serve` gives workers their sockets.

## ServerOptions reference

| Field | Default | Meaning |
| --- | --- | --- |
| `host` | `"127.0.0.1"` | Bind address. Loopback on purpose — set it explicitly to go public. |
| `port` | `8080` | `0` picks a free port; read it back with `server.port()`. |
| `backlog` | `512` | Listen backlog. |
| `max_connections` | `10000` | Concurrent connections; past it, accepts are rejected and counted. |
| `max_events` | `256` | Poller events per wake. |
| `poll_timeout_ms` | `25` | Short on purpose: a parked loop that wakes 40×/s stays out of macOS's idle heuristics, which otherwise delay kevent wakeups. |
| `idle_timeout_ms` | `30000` | Idle connection is closed. |
| `graceful_shutdown_ms` | `10000` | Drain budget after a stop. |
| `pending_timeout_ms` | `30000` | Unanswered deferred request → `503` and close. |
| `read_buffer_bytes` | `65536` | Per-connection read buffer. |
| `max_body_bytes` | `8388608` | Request body cap (8 MiB). |
| `max_response_body_bytes` | `16777216` | Response body cap (16 MiB). |
| `max_pending_output_bytes` | `33554432` | Queued unwritten output per connection (32 MiB). |
| `max_requests_per_connection` | `1000000` | Then the connection is closed. |
| `max_header_count` | `128` | Parser bound. |
| `max_header_bytes` | `65536` | Parser bound. |
| `max_target_bytes` | `8192` | Parser bound. |
| `max_head_span_bytes` | `16384` | Parser bound. |

Every value is validated at `bind`/`adopt`/`serve`; a non-positive limit or an
out-of-range port is a `config` error before anything opens.

## Errors

A handler that returns `err` never reaches the client raw.

| Error kind | Response |
| --- | --- |
| `"bad_request"` | `400`, with the error's own message as `detail`. |
| anything else | `500`. `detail` is the error message only when `AppOptions.detailed_errors` is on; otherwise a generic line pointing at the trace id. |

Both are `application/problem+json; charset=utf-8`:

```json
{
  "status": 404,
  "title": "Not Found",
  "detail": "No endpoint matches /nope",
  "traceId": "espresso-9"
}
```

The same shape covers `403` (CORS), `401` (API key), `404`, `405`, `429`, and
the `503` from a deferred timeout. Pair it with `request_logging` and the
`traceId` in a client's hands maps to exactly one log line.

If a handler already wrote a response before failing, that response is kept.

## Performance

Measured 2026-08-21 on an arm64 Mac (8 core), over loopback, `wrk`, all four
servers up at once and load applied to one at a time with the start order
rotated per round. JS lanes are `bun build --compile` binaries, four processes
with `reusePort`, `development: false`, `NODE_ENV=production` — benchmarking
Bun in its development default costs it 13–35% and is not a fair lane.
Espresso is a native `--release --lto --cpu native` build running **one
worker, one thread**. All lanes return byte-identical bodies.

| | start | peak RSS | cpu/req | c1 | c32 | c128 | p99 c32 / c128 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **espresso** (1 thread) | 11 ms | 5.5 MB | 5.94 µs | 46.4k | 168.4k | 172.2k | 0.38 / 1.49 ms |
| bun 1.4.0 (4 proc) | 36 ms | 82 MB | 6.78 µs | 38.6k | 159.7k | 165.0k | 0.41 / 1.55 ms |
| hono 4.13.3 (4 proc) | 50 ms | 87.3 MB | 7.8 µs | 36.7k | 137.1k | 142.1k | 0.76 / 1.85 ms |
| elysia 1.4.29 (4 proc) | 72 ms | 110.7 MB | 7.1 µs | 39.2k | 151.9k | 154.7k | 0.45 / 1.72 ms |

Across payload shapes, against Bun: small JSON 176.6k vs 148.3k, 648-byte
object 152.4k vs 139.2k, 53 KB list 9,355 vs 6,929 (+35%), POST echo with
parsing 142.6k vs 107.4k (+33%), plain text 181.4k vs 153.2k. Under a
fixed-rate generator (`h2load --h1 --rps`) espresso holds the lowest p99 at
80k/100k/120k req/s — 0.57 ms at 100k — with zero errors.

Numbers move with kernel, hardware, and payload. Measure your own shape before
believing anyone's table, including this one. The benchmark harness is not part
of this repository.

What makes it fast, briefly: the request/response objects are per-connection
and reused; literal routes resolve through a per-method hash map with no
decoding; the query string is parsed lazily and only once; response framing
writes straight into the connection's output queue; the poller fills a
caller-owned event list; the HTTP parser is recycled between requests; and
`TCP_NODELAY` is on, so a small response is not held for a coalescing timer.

## Building and shipping

```sh
beansc run main.b                                  # interpreter, fastest edit loop
beansc build main.b -o api                         # native
beansc build --release --lto --cpu native main.b -o api
beansc check main.b --target x86_64-unknown-linux-gnu
```

Cross-target checks that this repository keeps green:
`x86_64-unknown-linux-gnu`, `x86_64-pc-windows-gnu`, `aarch64-apple-darwin`.

A production checklist:

- Set `host` to the interface you mean. The default is loopback.
- Leave `detailed_errors` off.
- Put `security_headers` on, and `cors` on only if a browser needs it.
- Terminate TLS in front (see [Current boundary](#current-boundary)).
- Size `max_body_bytes` to your largest real request, not to the default.
- Add `request_logging` and keep the trace id.
- Route anything that waits through a `WorkerPool`.

## Development

```sh
bash test.sh              # interpreter suite + cross-target checks (~3 s)
bash test.sh --native     # also builds and runs the native smoke case (~3 min)
```

The suite covers dependency injection, routing, configuration and logging,
end-to-end features, a request fuzz case, the live server, and deferred
responses — each as a golden-output comparison under `tests/`.

`test.sh` uses `$BEANSC`, or `$BEANS_ROOT/build/beansc`, or a `beansc` on
`PATH`, in that order.

Examples:

```sh
beansc run examples/hello/main.b
beansc build --release examples/router_bench/main.b -o /tmp/router-bench && /tmp/router-bench
```

## Current boundary

**Handlers are synchronous.** Beans does not have first-class async closures
yet, so endpoint and middleware function values are plain functions. That is
not a "never wait" rule any more: waiting work goes behind `respond_later()`
and a `WorkerPool`, and the loop stays free. When async closures land, deferral
becomes the implementation detail underneath async handlers.

**TLS and HTTP/2 terminate in a reverse proxy.** This is sequencing, not a
wall. The Beans standard library already has a pollable server-side
`TlsListener` (PEM, PKCS#12, SNI, ALPN) and an `Http2Transport` at h2spec
parity with nghttp2's own server. Native TLS in Espresso needs a `TlsStream`
`Send` audit and want-read/want-write states in the connection driver; HTTP/2
then plugs in as a second connection driver selected by ALPN onto the same
`HttpContext` model. Both are planned right after 1.0. Until then the standard
library is usable directly for lower-level TLS, HTTP/2, or WebSocket work.

**Not in the box yet:** static file serving, sessions and cookies helpers,
model binding from JSON straight into action parameters, response schema
inference for OpenAPI, and content negotiation.

## License

Apache-2.0. See [LICENSE](LICENSE).
