# Changelog

This file records user-facing changes in each Espresso release.

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
