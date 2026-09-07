package espresso

import std.http
import std.io
import std.log
import std.net

/// Safe production defaults. Development may opt into detailed errors.
pub class AppOptions {
    pub detailed_errors: bool = false
    /// The `Server` header value, sent on every response. Empty by default —
    /// like Go's net/http and Bun, espresso identifies itself in no header
    /// unless asked to. Set it to a non-empty value (e.g. "espresso") to opt
    /// back in; those bytes are then framed on every response.
    pub server_header: string = ""
    /// Where a failed request's server-side record goes. `none` (the default)
    /// writes it to stderr — no logger to name, no shared state to race, one
    /// line per failure, and it never touches a program's stdout. Set a
    /// logger to route the record into std.log instead; then stderr is left
    /// alone. Either way the record carries the failure detail and the trace
    /// id the client was handed, so the generic production response's promise
    /// of a findable log is real. Naming a shared logger is the application's
    /// concern, not espresso's.
    pub error_logger: Option<log.Logger> = none

    pub fn init() {}
}

/// Collects services before the application is frozen.
pub class WebApplicationBuilder {
    pub services: ServiceCollection = new ServiceCollection()
    pub options: AppOptions = new AppOptions()
    built: bool = false

    pub fn init() {}

    pub fn build() -> Result<WebApplication> {
        if self.built {
            return err("the web application builder was already built", "app_built")
        }
        self.built = true
        return ok(new WebApplication(
            self.services.build_provider(), self.options))
    }
}

/// Routes and middleware over one root service provider.
pub class WebApplication {
    /// The root provider. Create scopes from it for work outside a
    /// request; inside one, use context.services.
    pub services: ServiceProvider
    options: AppOptions
    router: Router = new Router()
    middleware: List<fn(HttpContext,
        fn(HttpContext) -> Result<bool>) -> Result<bool>> = []
    trace_sequence: int = 0
    closed: bool = false

    fn init(services: ServiceProvider, options: AppOptions) {
        self.services = services
        self.options = options
    }

    /// Adds middleware in outer-to-inner order.
    pub fn use(layer: fn(HttpContext,
        fn(HttpContext) -> Result<bool>) -> Result<bool>) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        self.middleware.push(layer)
        return ok(true)
    }

    /// Adds an object middleware at the same position use() would. An
    /// object carries configuration and state; both forms share the one
    /// pipeline in registration order.
    pub fn use_middleware(layer: Middleware) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        self.middleware.push(
            fn(context: HttpContext,
               next: fn(HttpContext) -> Result<bool>) -> Result<bool> {
                return layer.handle(context, next)
            })
        return ok(true)
    }

    pub fn map(method: string,
               pattern: string,
               handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        return self.router.map(method, pattern, handler)
    }

    pub fn get(pattern: string,
               handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("GET", pattern, handler)
    }

    pub fn post(pattern: string,
                handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("POST", pattern, handler)
    }

    pub fn put(pattern: string,
               handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("PUT", pattern, handler)
    }

    pub fn patch(pattern: string,
                 handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("PATCH", pattern, handler)
    }

    pub fn delete(pattern: string,
                  handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("DELETE", pattern, handler)
    }

    /// Registers a protocol-upgrade endpoint at `pattern`.
    ///
    /// A request that asks to switch protocols runs the same middleware
    /// pipeline an ordinary request runs — authentication, cookies, an
    /// `Origin` check, rate limiting all apply to a handshake — and only then
    /// reaches this table. If a layer answers instead of calling `next`, that
    /// answer is sent and the socket is never handed over.
    pub fn map_upgrade(pattern: string,
                       handler: UpgradeHandler) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        return self.router.map_upgrade(pattern, handler)
    }

    fn run_pipeline(context: HttpContext, index: int) -> Result<bool> {
        if index >= self.middleware.len() {
            return self.router.dispatch(context)
        }
        let layer: fn(HttpContext,
            fn(HttpContext) -> Result<bool>) -> Result<bool> =
            self.middleware[index]
        let next: fn(HttpContext) -> Result<bool> =
            fn(inner: HttpContext) -> Result<bool> {
                return self.run_pipeline(inner, index + 1)
            }
        return layer(context, next)
    }

    // The same walk with the upgrade table as its terminal. It is a second
    // function rather than a parameterised one because the terminal is
    // captured by the `next` closure at every depth, and one extra captured
    // value on the ordinary request path is a cost every request would pay
    // for a case that happens at most once per connection.
    fn run_upgrade_pipeline(context: HttpContext, index: int) -> Result<bool> {
        if index >= self.middleware.len() {
            return self.router.dispatch_upgrade(context)
        }
        let layer: fn(HttpContext,
            fn(HttpContext) -> Result<bool>) -> Result<bool> =
            self.middleware[index]
        let next: fn(HttpContext) -> Result<bool> =
            fn(inner: HttpContext) -> Result<bool> {
                return self.run_upgrade_pipeline(inner, index + 1)
            }
        return layer(context, next)
    }

    /// One reusable per-connection context over the root provider.
    fn new_context(remote: net.Address) -> HttpContext {
        return new HttpContext(new HttpRequest(remote), self.services)
    }

    /// Resets `context` around a freshly parsed head, stamping a trace
    /// sequence. The request body streams in afterwards.
    fn begin_request(context: HttpContext,
                     head: http.Request) -> Result<bool> {
        self.trace_sequence += 1
        return context.begin(head, self.trace_sequence)
    }

    /// Runs the middleware pipeline and endpoint for the request currently
    /// held by `context`. The caller sends `context.response` afterwards and
    /// then calls `context.close()`.
    fn handle_context(context: HttpContext) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        context.open_scope()?
        match self.run_pipeline(context, 0) {
            ok(_) => {}
            err(problem) => {
                // A 500 hides its detail from the client behind the generic
                // message, so it must be recorded server-side first —
                // otherwise that message's promise of a findable log is a
                // lie. A 400 shows its own detail (it describes the client's
                // input) and needs no record.
                if problem.kind != "bad_request" &&
                   !context.response.completed {
                    self.record_failure(context, problem.msg)
                }
                self.write_failure(context, problem.msg, problem.kind)?
            }
        }
        // A deferred request answers through its Responder; the buffered
        // response object is never sent, so no defaults are stamped on it.
        if context.deferred { return ok(true) }
        if !context.response.completed {
            context.response.no_content()
        }
        if self.options.server_header != "" &&
           !context.response.headers.has("Server") {
            // A framework header, not a handler's: add it straight so it does
            // not mark the response as carrying a custom header (the head cache
            // includes Server and stays usable when it is opted in).
            context.response.headers.add("Server", self.options.server_header)
        }
        return ok(true)
    }

    /// Runs the pipeline for a request that asked to switch protocols.
    ///
    /// Afterwards exactly one of two things is true, and the connection fiber
    /// reads which: either `context.claim_upgrade()` names an endpoint and no
    /// response was completed — hand the socket over — or a response is ready
    /// to send and the connection stays HTTP to the end.
    ///
    /// A layer that completed a response wins over a selected endpoint even if
    /// it also called `next`. The socket is handed away irrevocably, so the
    /// only safe direction to resolve that contradiction is the one that keeps
    /// it: answer, and do not upgrade.
    fn handle_upgrade_context(context: HttpContext) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        context.open_scope()?
        match self.run_upgrade_pipeline(context, 0) {
            ok(_) => {}
            err(problem) => {
                if problem.kind != "bad_request" &&
                   !context.response.completed {
                    self.record_failure(context, problem.msg)
                }
                self.write_failure(context, problem.msg, problem.kind)?
            }
        }
        if context.deferred {
            // respond_later on an upgrade would leave the connection waiting
            // for a payload it can no longer frame, on a socket it may no
            // longer own. Refuse the whole request instead of hanging.
            context.response.reset()
            self.record_failure(
                context,
                "a request that asked to switch protocols armed a Responder")
            self.write_failure(
                context,
                "a protocol upgrade cannot defer its response", "upgrade")?
        }
        if context.response.completed {
            // Whatever the terminal chose, an answer exists: keep the socket.
            let dropped: Option<UpgradeHandler> = context.claim_upgrade()
        } else if context.upgrade.is_some() {
            return ok(true)
        } else {
            context.response.no_content()
        }
        if self.options.server_header != "" &&
           !context.response.headers.has("Server") {
            context.response.headers.add("Server", self.options.server_header)
        }
        return ok(true)
    }

    // The server-side record for a failed request — the piece the generic
    // production response promises ("use the trace id to find the server
    // log") but that nothing wrote before. `detail` is the returned err's
    // message, or a contained panic's "runtime panic at L:C: ..." text (which
    // already embeds the source position); it is paired with the request line
    // and the SAME trace id the client was handed, so an operator can
    // correlate the log line with the response the client reports.
    //
    // The default sink is stderr. Every worker thread writes to stderr
    // independently, so there is nothing to name and no shared state to race
    // — that is what stderr is for. An application that wants structured logs
    // sets options.error_logger; then the record goes there and stderr is
    // left untouched, so espresso never writes to a program's stdout and a
    // configured application keeps its own log shape. Recording is
    // best-effort: a logging-backend failure must not fail a request whose
    // response is already decided.
    fn record_failure(context: HttpContext, detail: string) {
        match self.options.error_logger {
            some(logger) => {
                let recorded: Result<bool> = logger.log_fields(
                    log.Level.error, detail,
                    [new log.Field("method", context.request.method),
                     new log.Field("path", context.request.path),
                     new log.Field("traceId", context.trace_id())])
            }
            none => {
                io.eprintln(
                    "[espresso] request failed traceId={context.trace_id()} {context.request.method} {context.request.path}: {detail}")
            }
        }
    }

    // Renders a failed pipeline into the context's response as problem+json,
    // through the one detailed_errors gate. A 400 bad_request describes the
    // client's own input, so it is shown as-is; every other failure — a 500,
    // a contained panic among them — is a server internal, hidden behind the
    // generic detail and the trace id in production. Shared by handle_context
    // (a returned err) and the server's dispatch (a contained panic) so the
    // two paths render the identical body and cannot drift apart again.
    // Logging is the caller's job (record_failure), because only the
    // hidden-detail case needs a record.
    fn write_failure(context: HttpContext,
                     detail: string, kind: string) -> Result<bool> {
        if kind == "bad_request" && !context.response.completed {
            return write_problem(context, 400, "Bad Request", detail)
        }
        if !context.response.completed {
            let shown: string = if self.options.detailed_errors {
                detail
            } else {
                "The request failed. Use the trace id to find the server log."
            }
            return write_problem(
                context, 500, "Internal Server Error", shown)
        }
        return ok(true)
    }

    // Deferred responses come from worker threads without a context, so the
    // server asks for the header it should stamp on them.
    fn server_header() -> string { return self.options.server_header }

    /// Runs one already-parsed standard-library request through Espresso.
    /// The caller must close the returned context after sending its response.
    pub fn handle(served: http.ServedRequest,
                  remote: net.Address) -> Result<HttpContext> {
        if self.closed { return err("the application is closed", "closed") }
        let context: HttpContext = self.new_context(remote)
        self.begin_request(context, served.head)?
        context.request.body.append(served.body)
        context.request.keep_alive = served.keep_alive
        if served.trailer_fields.count() != 0 {
            context.request.trailer_fields = served.trailer_fields
        }
        self.handle_context(context)?
        return ok(context)
    }

    /// Closes the root provider and its singleton services.
    pub fn close() -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        self.closed = true
        return self.services.close()
    }
}
