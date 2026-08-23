# Changelog

This file records user-facing changes in each Espresso release.

## Unreleased

## [0.3.0] - 2026-08-23

Breaking async-v2 migration.

### Added

- Async route handlers are the default for `map`, `get`, `post`, `put`,
  `patch`, and `delete`. The matching `_sync` forms dispatch synchronous
  handlers inline.
- Controllers may use sync or async actions. Mapping records the reflection
  effect once and dispatches async actions with `Method.call_async`.
- `WorkerPool.execute<T>` runs a blocking Send job on the fixed crew and
  asynchronously returns its value.
- Async `WebServer.run`, `serve`, and TestHost request methods.
- Structured TaskGroup ownership for accepted connections, async socket
  readiness, timers, shutdown Event, and request deadlines.

### Changed

- Middleware, `Authorizer`, and the full request pipeline are async.
- `request_timeout_ms` replaces `pending_timeout_ms`. The old field and
  `server:pending-timeout-ms` config key remain as deprecated aliases for
  this release. Zero leaves the new field unset, the effective default is
  still 30 seconds, and a positive new value always wins. `poll_timeout_ms`
  and `max_events` are removed.
- `DetachedResult` now accepts only a response already filled on the current
  context.

### Removed

- `Responder`, `respond_later`, completion mailboxes, deferred response state,
  and `WorkerPool.submit`.

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
