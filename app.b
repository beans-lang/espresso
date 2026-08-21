package espresso

import std.http
import std.net

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
    services: ServiceProvider
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

    pub fn map(method: string,
               pattern: string,
               handler: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        return self.router.map(method, pattern, handler)
    }

    pub fn get(pattern: string,
               handler: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        return self.map("GET", pattern, handler)
    }

    pub fn post(pattern: string,
                handler: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        return self.map("POST", pattern, handler)
    }

    pub fn put(pattern: string,
               handler: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        return self.map("PUT", pattern, handler)
    }

    pub fn patch(pattern: string,
                 handler: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        return self.map("PATCH", pattern, handler)
    }

    pub fn delete(pattern: string,
                  handler: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        return self.map("DELETE", pattern, handler)
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

    fn next_trace_id() -> string {
        self.trace_sequence += 1
        return "espresso-{self.trace_sequence}"
    }

    /// Runs one already-parsed standard-library request through Espresso.
    /// The caller must close the returned context after sending its response.
    pub fn handle(served: http.ServedRequest,
                  remote: net.Address) -> Result<HttpContext> {
        if self.closed { return err("the application is closed", "closed") }
        let request: HttpRequest = HttpRequest.from_served(served, remote)?
        let scope: ServiceProvider = if self.services.has_registrations() {
            self.services.create_scope()?
        } else { self.services }
        let context: HttpContext = new HttpContext(
            move request, scope, self.next_trace_id())
        match self.run_pipeline(context, 0) {
            ok(_) => {}
            err(problem) => {
                if !context.response.completed {
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
        return ok(context)
    }

    /// Closes the root provider and its singleton services.
    pub fn close() -> Result<bool> {
        if self.closed { return err("the application is closed", "closed") }
        self.closed = true
        return self.services.close()
    }
}
