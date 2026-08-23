package espresso

import std.http
import std.net

class ContextHandoff {
    context: HttpContext
    armed: bool = true

    fn init(context: HttpContext) { self.context = context }

    fn close_if_armed() {
        if self.armed {
            let ignored: Result<bool> = self.context.close()
        }
    }

    fn disarm() { self.armed = false }
}

/// Safe production defaults. Development may opt into detailed errors.
pub class AppOptions {
    pub detailed_errors: bool = false
    pub server_header: string = "espresso"

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
    middleware: List<async fn(HttpContext,
        async fn(HttpContext) -> Result<bool>) -> Result<bool>> = []
    trace_sequence: int = 0
    closed: bool = false

    fn init(services: ServiceProvider, options: AppOptions) {
        self.services = services
        self.options = options
    }

    /// Adds middleware in outer-to-inner order.
    pub fn use(layer: async fn(HttpContext,
        async fn(HttpContext) -> Result<bool>) -> Result<bool>) -> Result<bool> {
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
            async fn(context: HttpContext,
               next: async fn(HttpContext) -> Result<bool>) -> Result<bool> {
                return await layer.handle(context, next)
            })
        return ok(true)
    }

    pub fn map(method: string,
               pattern: string,
               handler: async fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        return self.router.map(method, pattern, handler)
    }

    pub fn get(pattern: string,
               handler: async fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("GET", pattern, handler)
    }

    pub fn post(pattern: string,
                handler: async fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("POST", pattern, handler)
    }

    pub fn put(pattern: string,
               handler: async fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("PUT", pattern, handler)
    }

    pub fn patch(pattern: string,
                 handler: async fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("PATCH", pattern, handler)
    }

    pub fn delete(pattern: string,
                  handler: async fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map("DELETE", pattern, handler)
    }

    /// Maps a synchronous handler and dispatches it inline.
    pub fn map_sync(method: string,
                    pattern: string,
                    handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        return self.router.map_sync(method, pattern, handler)
    }

    pub fn get_sync(pattern: string,
                    handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map_sync("GET", pattern, handler)
    }

    pub fn post_sync(pattern: string,
                     handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map_sync("POST", pattern, handler)
    }

    pub fn put_sync(pattern: string,
                    handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map_sync("PUT", pattern, handler)
    }

    pub fn patch_sync(pattern: string,
                      handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map_sync("PATCH", pattern, handler)
    }

    pub fn delete_sync(pattern: string,
                       handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        return self.map_sync("DELETE", pattern, handler)
    }

    async fn run_pipeline(context: HttpContext, index: int) -> Result<bool> {
        if index >= self.middleware.len() {
            return await self.router.dispatch(context)
        }
        let layer: async fn(HttpContext,
            async fn(HttpContext) -> Result<bool>) -> Result<bool> =
            self.middleware[index]
        let next: async fn(HttpContext) -> Result<bool> =
            async fn(inner: HttpContext) -> Result<bool> {
                return await self.run_pipeline(inner, index + 1)
            }
        return await layer(context, next)
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
    async fn handle_context(context: HttpContext) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        context.open_scope()?
        match await self.run_pipeline(context, 0) {
            ok(_) => {}
            err(problem) => {
                if problem.kind == "bad_request" &&
                   !context.response.completed {
                    write_problem(
                        context, 400, "Bad Request", problem.msg)?
                } else if !context.response.completed {
                    let detail: string = if self.options.detailed_errors {
                        problem.msg
                    } else {
                        "The request failed. Use the trace id to find the server log."
                    }
                    write_problem(
                        context, 500, "Internal Server Error", detail)?
                }
            }
        }
        if !context.response.completed {
            context.response.no_content()
        }
        if self.options.server_header != "" &&
           !context.response.headers.has("Server") {
            context.response.header("Server", self.options.server_header)
        }
        return ok(true)
    }

    /// Runs one already-parsed standard-library request through Espresso.
    /// The caller must close the returned context after sending its response.
    pub async fn handle(served: http.ServedRequest,
                        remote: net.Address) -> Result<HttpContext> {
        if self.closed { return err("the application is closed", "closed") }
        let context: HttpContext = self.new_context(remote)
        let handoff: ContextHandoff = new ContextHandoff(context)
        defer handoff.close_if_armed()
        self.begin_request(context, served.head)?
        context.request.body.append(served.body)
        context.request.keep_alive = served.keep_alive
        if served.trailer_fields.count() != 0 {
            context.request.trailer_fields = served.trailer_fields
        }
        await self.handle_context(context)?
        handoff.disarm()
        return ok(context)
    }

    /// Closes the root provider and its singleton services.
    pub fn close() -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        self.closed = true
        return self.services.close()
    }
}
