# Changelog

This file records user-facing changes in each Espresso release.

## [Unreleased]

### Changed

- **A connection caches its response head instead of rebuilding it each
  request.** A connection answering the same shape repeatedly (a hot route, a
  benchmark) now frames the head by reusing a cached copy — keyed by (status,
  reason, content-type, keep-alive) — writing only the Content-Length digits and
  patching the Date in place, rather than re-validating the headers and building
  the head line by line. The cached bytes are std.http's own (the entry is built
  by calling `encode_response_head_append`), so the wire output is byte-for-byte
  unchanged; a response with a custom header, no content type, a HEAD, or a
  body-forbidden status takes the original path. On /json this is ~0.6 µs less
  user time per request (~19%). (beans-lang/beans#140)

- **A request body no longer grows unboundedly with a connection's lifetime.**
  The request body is sized to its declared `Content-Length` before its pieces
  arrive, so assembling a body larger than one read fills one allocation instead
  of regrowing it; and once a body that outgrew a read has been served, its
  buffer is released rather than kept for the connection's life (`resize(0)`
  between requests frees no pages). Without this, a keep-alive connection that
  once received a large body held that capacity — up to `max_body` — forever, so
  a client could make every connection retain its maximum by sending one large
  request each. `ServerStats` now reports `request_buffers_released` and
  `request_bodies_presized`. (beans-lang/beans#140)

- **The `Server` header is no longer sent by default.** `AppOptions
  .server_header` now defaults to `""`, so — like Go's `net/http` and Bun —
  espresso adds no `Server` header unless asked. The 18 bytes it used to frame
  on every response were 1–2% of the small routes. Set `server_header` to a
  non-empty value (`"espresso"` restores the old behaviour) to opt back in. No
  test golden captured the header, so none changed. (beans-lang/beans#140)

- **A response holds the handler's payload by reference, not by copy.** A
  `string` body (`text`, `json_text`, `html`, and the results that build on
  them) is kept as the handler's own string; a `Bytes` body is moved in. The
  server frames the head from the payload's length and either appends a small
  payload to its output queue or sends a large one beside the head with one
  vectored write — the payload is never staged in a per-connection buffer that
  grows to its size and keeps that capacity between requests. For 32 connections
  each holding a 1 MiB response that removes ~32 MiB of resident memory. The
  bytes on the wire are byte-for-byte unchanged. As a consequence
  `HttpResponse.body` now holds only a **bytes-form** payload and is empty for a
  string response; read the payload in either form with the new
  `HttpResponse.body_bytes()`, and query the form with `is_text_body()`,
  `text_payload()` and `body_len()`. (beans-lang/beans#140)

### Added

- **Responses carry a `Date` header** (RFC 9110 §6.6.1). Every response an
  origin server frames onto a socket now includes an IMF-fixdate `Date` in
  GMT — on 2xx/3xx/4xx, where it is a MUST, and on 5xx too — unless the
  handler already set its own. The value is formatted once per wall-clock
  second and reused, so the hot path pays a cached string, not a
  `DateTime.now()` and a format per request. `TestHost` responses do not
  carry it on purpose: a test host never frames a message onto the wire, so
  RFC 9110's origin-server rule does not apply and a time-varying header
  would only make header assertions clock-dependent (`tests/date.b`). (#2)
- **A failed request leaves a server-side record.** Whenever espresso hides a
  failure's detail behind the generic production message, it first writes that
  detail — the panic text and its `runtime panic at <line>:<col>` position, or
  a returned `err`'s message, together with the request method and path and
  the *same* trace id the client was handed — to a record, so
  "use the trace id to find the server log" is a real promise rather than a
  lie. The default sink is **stderr**: one line per failure, and because every
  worker thread writes to stderr independently there is nothing to name and no
  shared state to race, and it never touches a program's stdout. Set
  `AppOptions.error_logger` to a `std.log.Logger` to route the record there
  instead — then stderr is left alone. `RequestLog` cannot fill this role: it
  runs *inside* the pipeline, which a panic unwinds straight past, so it logs
  nothing for exactly the requests that failed hardest (`tests/panic.b`). (#4)

### Requirements

- Espresso now needs **Beans 0.1.36 or newer**. `std.calendar`, which formats
  the `Date` header, first ships in 0.1.36; the contained-panic unwind that
  makes a panicking handler reclaim what it held first ships in 0.1.35.

### Security

- **A panicking handler no longer leaks its panic message or source position
  to the client.** A handler that returned an `err` already passed the
  `detailed_errors` gate — production got a generic detail plus a trace id, as
  `application/problem+json`. A handler that *panicked* did not: the panic
  unwound past that gate and the connection wrote the runtime's
  `runtime panic at <line>:<col>: <message>` verbatim as a bare `text/plain`
  500, so whatever the message interpolated (the reported case put a
  connection string in it; a row id, a customer identifier, an internal
  hostname or a file path are all ordinary things to name in a panic) and the
  source coordinates of the running binary went to the remote client. Panics
  are reachable from input an author never intended — an index out of range,
  an `expect` on a `none`, an integer divide by zero — so "do not panic in a
  handler" was never a mitigation the framework could rely on. The panic path
  now renders through the *same* gate and the *same* problem+json shape (with
  a `traceId`) the returned-`err` path uses: `detailed_errors` off answers the
  generic detail and the trace id, on answers the panic text. The 400
  `bad_request` arm of the same `dispatch` block shares the shape. A contained
  panic is still fatal to its connection. (#4)

### Changed

- **One engine, on fibers.** The event-loop state machine is gone: every
  connection is a pinned fiber that reads, parses, dispatches, and
  flushes in a straight line, parking in the worker's netpoller between
  requests. The interest juggling, token maps, pause/replay machinery,
  and the acceptor's intake locks all fell out — `serve` now hands each
  worker its connections through a plain channel, and closing the channel
  is the stop signal. Requires Beans with fibers (`brew`/`TaskGroup`).
- **A panicking handler now costs its request, not the server.** Each
  request runs behind a fiber shield: a panic surfaces as the request's
  500 — gated by `detailed_errors` exactly as a returned `err` is, so the
  panic text and its source position stay off the wire in production (see
  Security, #4) — the connection closes cleanly, and every other connection
  keeps flowing (`tests/panic.b` is the drill).
- **A contained panic reclaims what the request held, and closes its
  connection.** On Beans with the runtime unwind (0.1.35+), a panicking
  handler runs its frames' `defer`s and drops its locals on the way out, so
  buffers, files, locks and DI scope are released instead of leaked;
  `tests/panic_reclaim.b` drives 100 panics and shows a defer-decremented
  depth counter back at 0 and a deinit-counted resource count at 100, on
  both backends. Closing the connection that saw the panic (already the
  behaviour, now stated and tested) bounds anything a half-finished request
  left on the reused `HttpContext`. **Windows has no runtime unwind yet**
  (the beans backend emits unwind pads only for ELF/Mach-O on x86-64/arm64),
  so on a Windows target a contained panic still abandons the frame and
  leaks exactly as before — the containment holds, the reclamation does not,
  until a beans-side COFF unwind lands. (#3)
- **Deferred responses ride per-request channels.** `respond_later()`
  works as before; inside, the Responder answers into a one-slot channel
  the connection fiber waits on, so request order under pipelining holds
  by construction, a late responder sinks into its orphaned channel, and
  the pending timeout still answers 503. The mailbox, tokens, and
  generations are gone.
- Graceful shutdown wakes parked keep-alive connections by shutting their
  reads; connections still working past `graceful_shutdown_ms` lose their
  writes too. `poll_timeout_ms` now means how fast the accept loop
  notices `control().stop()`.

### Fixed

- A deferred handler that took a `Responder` with `respond_later()` and then
  panicked before handing it off no longer parks its connection fiber until
  `pending_timeout_ms` (a 30s stall by default, per abandoned request). The
  dropped Responder now wakes the waiter at once with a 500. A Responder that
  answered normally, or that is dropped after the request already timed out,
  is unaffected. (#3)
- `ServiceProvider.resolve_value` releases its cycle-detection and
  singleton-depth bookkeeping through a `defer`, so a factory (a
  constructor) that panics no longer strands a `resolving` entry — which
  turned the next resolve on that provider into a false "dependency cycle" —
  or a `singleton_depth` bump — which turned the next scoped resolve into a
  false "singleton cannot capture scoped" (`tests/di_panic.b`). (#3)

### Removed

- `IntakeQueue`, `WebServer.set_intake`, and `LoopMailbox` — acceptor
  plumbing of the old event loop with no fiber-engine counterpart.

## [0.2.0] - 2026-08-22

### Added (post-tag)

- `@espresso.service(lifetime: ServiceLifetime...)` and
  `espresso.add_services(builder)`: opt-in discovery over explicit
  registration. A marked class registers as itself and as each interface
  it directly implements, forwarded so one scope resolves the same
  instance under every name; the lifetime field is the enum and defaults
  to scoped. Duplicate claims, `@service` on a `@controller`, and
  `@service` on a language `singleton class` (which reflection cannot
  construct) are scan-time errors with advice.


One breaking release: the API changes once, completely, while it still
costs nothing to change it. Requires Beans 0.1.29 for explicit type
arguments, package functions as values, and reflection that resolves
once — an annotated controller action now runs within 2x of a free
function (~225,000 req/s through TestHost against ~450,000), where 0.1
measured 95x slower.

### Added

- `ActionResult`: handlers and controller actions return a result value
  the router executes — `TextResult`, `JsonResult`, `JsonTextResult`,
  `NoContentResult`, `StatusResult`, `ProblemResult`, `BytesResult`,
  `HtmlResult`, `DetachedResult` — with free constructors
  (`espresso.text`, `espresso.json_text`, `espresso.problem`,
  `espresso.detached`, …). The old write-to-`context.response` handler
  form is gone rather than deprecated.
- Model binding by parameter annotation, compiled to typed extractors at
  map time: `@espresso.route`, `@espresso.query` (with `default:` and
  `required:`), `@espresso.header`, `@espresso.body` (JSON through the
  type's initializer, nested objects and scalar lists included),
  `@espresso.inject`, and a bare `HttpContext` parameter. Client
  mistakes answer 400 problem+json, never 500.
- Filters, composed per action at map time: `@espresso.auth(policy:)`
  through a registered `espresso.Authorizer` service (403 when it
  declines), `@espresso.validate` running each bound body's
  `validate(errors)` (400 with field problems), and
  `@espresso.limit(rpm:)` (429 with Retry-After).
- An optional `espresso.Controller` base class carrying the request
  context and the result helpers: `self.ok`, `self.ok_text`,
  `self.created`, `self.no_content`, `self.not_found`,
  `self.bad_request`, `self.problem`.
- Middleware as objects: `espresso.Middleware` (one `handle(context,
  next)` method) and `app.use_middleware(new ...)`, sharing the one
  pipeline with function middleware — which can now be a package
  function passed directly, `app.use(espresso.security_headers)`.
- Typed service registration: `add_singleton<S, I>()`,
  `add_scoped<S, I>()`, `add_transient<S, I>()`, self-registration
  `singleton<T>()` / `scoped<T>()` / `transient<T>()`, and
  `provider.resolve<T>()`. The runtime-typed `add` stays as the escape
  hatch the controller scanner itself uses.
- Server-side views: `espresso.Views` compiles a small mustache-style
  template language once (`{{name}}` escaped, `{{{name}}}` raw,
  `{{#section}}`, `{{^empty}}`, dotted paths); `espresso.view(name,
  model)` renders a typed model as one more `ActionResult`.
  `add_views(builder, views)` registers the collection.
- `espresso.RequestLog`: request logging middleware over `std.log`, and
  `espresso.console_logger(name)` for the common sink.
- `examples/taskhub`: a working task-tracking service — stores behind
  interfaces, auth policies, validation, a rendered dashboard —
  runnable as a server or as an in-memory demo.
- `examples/lanes_bench`: the controller-vs-function gate, kept in the
  tree.

### Changed

- Controller verb annotations are the short names: `@espresso.get`,
  `@espresso.post`, `@espresso.put`, `@espresso.patch`,
  `@espresso.delete` (were `http_get` …). `@espresso.controller` is
  unchanged.
- Actions take bound parameters and return `Result<ActionResult>`; the
  one-borrowed-HttpContext signature requirement is gone.
- `WebApplication.services` is public: create scopes outside a request
  from the root provider.

### Removed

- `ServiceKey<T>` and `espresso.service(provider, key)` — explicit type
  arguments made the witness object unnecessary. Use
  `provider.resolve<T>()`.
- The two-argument `add_transient/add_scoped/add_singleton(type_of(S),
  type_of(I))` forms — use the generic forms; `add(service, impl,
  lifetime)` remains for runtime types.
- Espresso's own `Logger`, `LogRecord`, `LogLevel` and
  `json_console_log`: logging is `std.log`, which already had sinks,
  levels, structured fields and an exportable reader. One deliberate
  loss: there is no callback sink — user code never runs inside the
  logger, by `std.log` design.

## Unreleased

## [0.1.0] - 2026-08-22

First release. Requires Beans 0.1.28 or newer.

### Added

- `WebApplicationBuilder`, `WebApplication`, and `AppOptions`: the builder
  collects services, `build()` freezes them, and the application owns routes,
  middleware, and the root service provider.
- `WebServer`: a level-triggered non-blocking HTTP/1.1 event loop over
  `std.poll`, `std.net`, and `std.http`, with bounded connections, parser
  fields, request and response bodies, pending output, requests per
  connection, idle time, and drain time. `bind`, `adopt`, `run`, `close`,
  `port`, and a copyable `ServerControl` for graceful stops from another
  thread.
- `Router`: literal, `{name}`, and trailing `{*rest}` segments, specificity
  ordering, conflict detection at map time, automatic `HEAD` from `GET`,
  `OPTIONS` with `Allow`, and `405`/`404` problem responses. Fully literal
  routes on a plain path resolve through a per-method hash map with no
  decoding and no allocation.
- `HttpContext`, `HttpRequest`, `HttpResponse`, and `QueryValues`: route
  values, lazily parsed query fields, decoded path segments, trailers, and a
  per-request trace id. Request and response objects are reused per
  connection.
- Dependency injection: `ServiceCollection`, `ServiceProvider`, transient,
  scoped, and singleton lifetimes, constructor injection by type, factory
  registration, and `ServiceKey<T>` resolution. Missing services, cycles,
  root use of scoped services, and singleton capture of scoped services are
  all refused.
- Controllers through `std.reflect`: `@controller`, `@http_get`, `@http_post`,
  `@http_put`, `@http_patch`, `@http_delete`, with `add_controllers` and
  `map_controllers`.
- `respond_later()` and `Responder`: a move-only `Send` handle that finishes a
  request from any thread. The connection stops reading until it answers, so
  pipelined responses stay in order; one send wins; an unanswered request gets
  `503` after `pending_timeout_ms`.
- `WorkerPool`: a fixed crew over one bounded channel, with blocking `submit`
  for backpressure and a `close` that drains before joining.
- `serve` and `recommended_workers`: one application factory per worker, each
  with its own loop, application, and service graph, fed round-robin by the
  calling thread.
- Middleware: `security_headers`, `cors`, `api_key` with a constant-time
  compare, `fixed_window_rate_limit` with a bounded client table, and
  `request_logging`.
- `Configuration`: layered string configuration from explicit sets, a known
  list of environment variables, and `--key=value` arguments, plus
  `configure_server` for the standard `server:*` keys.
- `Logger`, `LogRecord`, `LogLevel`, and a one-line JSON console sink.
- `ValidationErrors` and `write_validation_problem` for RFC 9457-style
  validation problems.
- `map_openapi` and `openapi_json`: an OpenAPI 3.1 snapshot of the route
  table.
- `TestHost` and `TestResponse`: the full pipeline without a socket.
- Errors as `application/problem+json`, with a trace id and internal detail
  hidden unless `AppOptions.detailed_errors` is on.
