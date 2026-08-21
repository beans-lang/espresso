# Espresso

Espresso is an OOP web API framework for Beans. Its shape is close to ASP.NET Core: a builder, built-in dependency injection, middleware, routing, controllers, request scopes, configuration, structured logs, validation, security helpers, OpenAPI, and an in-memory test host.

The server is a level-triggered nonblocking HTTP/1.1 loop. It uses `std.poll`, `std.http`, and bounded input and output buffers. The same code builds for macOS, Linux, and Windows.

## Hello API

```beans
import espresso

fn hello(context: espresso.HttpContext) -> Result<bool> {
    let name: string = context.request.route("name").or("world")
    context.response.text(200, "OK", "Hello, {name}!")
    return ok(true)
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/hello/\{name\}", hello).expect("route")

    let server: espresso.WebServer = espresso.WebServer.bind(
        app, new espresso.ServerOptions()).expect("server")
    server.run().expect("run")
}
```

Run the full example from the Beans repository so the local runtime is found:

```sh
./build/beansc run ../community-libs/espresso/examples/hello/main.b
```

## Workers

`espresso.serve` takes one application factory per worker and blocks until
they return. One factory serves from the calling thread. With more, the
calling thread accepts connections and deals them round-robin to the
workers, and each worker runs its own event loop, application, and service
provider. Workers share nothing.

Start from `espresso.recommended_workers()` unless you have measured
otherwise. It returns 1: on macOS a single loop matches a four-process Bun
lane's throughput at lower CPU per request, because the kernel serializes
accepts through one listener and extra loops mostly buy contention. Give
more workers only to CPU-heavy handlers that saturate the one loop — and
route blocking work through a `WorkerPool` either way, which is what keeps
a single loop honest.

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

A handler's request objects are reused for the next request on the same
connection, so copy anything that must outlive the handler. `request.path`
is the raw undecoded path; `decoded_path()` returns the decoded form.
`request.query()` parses the query string the first time it is called, and
`context.trace_id()` builds its id the same way.

## Blocking work

Handlers run on the event loop, so they must not block it. Work that waits
— a database call, a slow computation, an outside service — goes to a
`WorkerPool`, and the request finishes later through a `Responder`:

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
handle. The connection stops reading until the responder answers, so
pipelined requests behind it still get their responses in order. Exactly
one sending call wins; a late or repeated send is dropped once the request
is answered or the connection is gone. A deferred request nobody answers
gets a `503` after `ServerOptions.pending_timeout_ms` (default 30 s) and
the connection closes.

The pool is plain threads over one channel. `submit` blocks when
`queue_depth` jobs are already waiting — backpressure, never loss — and
`close()` lets queued jobs finish, then joins the threads. With
`espresso.serve`, build one pool per worker inside its factory: the pool
handle stays on its own loop, and only the jobs are `Send`.

## Dependency injection

Register services before `build()`. Constructor parameters are resolved by type.

```beans
builder.services.add_singleton(type_of(Clock), type_of(SystemClock))?
builder.services.add_scoped(type_of(Store), type_of(SqlStore))?
builder.services.add_transient(type_of(Handler), type_of(Handler))?
```

Espresso checks missing services, cycles, root use of scoped services, and singleton capture of scoped services. It releases scoped and singleton caches in reverse creation order.

## Controllers

Call `espresso.add_controllers(builder)` before build and `espresso.map_controllers(app)` after build. Controller actions are public synchronous methods with this exact shape:

```beans
@espresso.controller(route: "/api")
pub class UsersController {
    store: UserStore

    pub fn init(store: UserStore) { self.store = store }

    @espresso.http_get(route: "/users/\{id\}")
    pub fn get(context: espresso.HttpContext) -> Result<bool> {
        // write context.response
        return ok(true)
    }
}
```

## Production controls

`ServerOptions` bounds connections, parser fields, request bodies, response bodies, pending output, requests per connection, idle time, deferred-response time, and graceful shutdown time. The default bind address is loopback. `ServerControl.stop()` wakes the poller and starts graceful shutdown; a graceful stop waits for in-flight deferred responses.

Useful middleware:

- `security_headers`
- `cors(options)`
- `api_key(header, secret)`
- `fixed_window_rate_limit(limit, window_ms, max_clients = 65536)`
- `request_logging(logger)`

Errors use `application/problem+json`. Production mode hides internal error text and includes a trace id.

## JSON and validation

Use `espresso.body_json` and `espresso.write_json` for the JSON DOM. For typed structs, call Beans `json.decode_bytes` and `json.encode`, then pass encoded text to `espresso.write_json_text`.

`ValidationErrors` supplies required, byte-length, and integer-range checks. `write_validation_problem` returns a structured 400 response.

## OpenAPI and tests

```beans
espresso.map_openapi(app)?
let host: espresso.TestHost = new espresso.TestHost(app)
let response: espresso.TestResponse = host.get("/hello/Beans")?
```

Run the fast suite:

```sh
bash ../community-libs/espresso/test.sh
```

Add `--native` for interpreter/native parity. The suite also checks Linux, Windows, and macOS targets.

Run the router benchmark as native code:

```sh
./build/beansc build ../community-libs/espresso/examples/router_bench/main.b -o /tmp/espresso-router-bench
/tmp/espresso-router-bench
```

Run the HTTP JSON benchmark against Bun with `wrk`:

```sh
../community-libs/espresso/examples/json_bench/run.sh
```

Both servers match `GET /json`, create and serialize the same typed JSON
shape for every request, and return the same response body and content type.

## Current boundary

Beans does not yet have first-class async closures, so endpoint and
middleware function values are synchronous. That is no longer a "never
wait" rule: blocking work goes behind `respond_later()` and a `WorkerPool`,
and the event loop stays free. When async closures land in Beans, deferral
becomes the implementation detail under async handlers.

TLS and HTTP/2 termination still sit in a reverse proxy. This is
sequencing, not a wall: the standard library already has a pollable
server-side `TlsListener` (PEM, PKCS#12, SNI, ALPN) and an
`Http2Transport` at h2spec parity with nghttp2's own server. Native TLS in
espresso needs a `TlsStream` `Send` audit and want-read/want-write states
in the connection driver; HTTP/2 then plugs in as a second connection
driver selected by ALPN onto the same `HttpContext` model. Both are planned
right after 1.0. The standard library remains usable directly today for
lower-level TLS, HTTP/2, or WebSocket handling.
