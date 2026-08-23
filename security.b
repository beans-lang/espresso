package espresso

import std.time

pub class CorsOptions {
    pub allowed_origins: List<string> = []
    pub allowed_methods: List<string> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    pub allowed_headers: List<string> = ["Content-Type", "Authorization"]
    pub allow_credentials: bool = false
    pub max_age_seconds: int = 600

    pub fn init() {}

    fn allows(origin: string) -> bool {
        return self.allowed_origins.contains("*") ||
               self.allowed_origins.contains(origin)
    }
}

/// Strict CORS middleware. Wildcard origins cannot be combined with cookies.
pub fn cors(options: CorsOptions) -> Result<
    async fn(HttpContext,
             async fn(HttpContext) -> Result<bool>) -> Result<bool>> {
    if options.allow_credentials && options.allowed_origins.contains("*") {
        return err("CORS credentials cannot use a wildcard origin", "config")
    }
    if options.max_age_seconds < 0 {
        return err("CORS max age cannot be negative", "config")
    }
    return ok(async fn(context: HttpContext,
                 next: async fn(HttpContext) -> Result<bool>) -> Result<bool> {
        match context.request.headers.get("Origin") {
            none => { return await next(context) }
            some(origin) => {
                if !options.allows(origin) {
                    return write_problem(
                        context, 403, "Forbidden", "Origin is not allowed")
                }
                let shown_origin: string = if options.allowed_origins.contains("*") {
                    "*"
                } else { origin }
                context.response.header("Access-Control-Allow-Origin", shown_origin)
                context.response.header("Vary", "Origin")
                if options.allow_credentials {
                    context.response.header(
                        "Access-Control-Allow-Credentials", "true")
                }
                if context.request.method == "OPTIONS" &&
                   context.request.headers.has("Access-Control-Request-Method") {
                    context.response.header(
                        "Access-Control-Allow-Methods",
                        options.allowed_methods.join(", "))
                    context.response.header(
                        "Access-Control-Allow-Headers",
                        options.allowed_headers.join(", "))
                    context.response.header(
                        "Access-Control-Max-Age", "{options.max_age_seconds}")
                    context.response.no_content()
                    return ok(true)
                }
                return await next(context)
            }
        }
    })
}

/// Common browser hardening headers for API responses.
pub async fn security_headers(
        context: HttpContext,
        next: async fn(HttpContext) -> Result<bool>) -> Result<bool> {
    let result: Result<bool> = await next(context)
    context.response.header("X-Content-Type-Options", "nosniff")
    context.response.header("X-Frame-Options", "DENY")
    context.response.header("Referrer-Policy", "no-referrer")
    context.response.header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
    return result
}

fn constant_time_equal(left: string, right: string) -> bool {
    let a: Bytes = Bytes.from(left)
    let b: Bytes = Bytes.from(right)
    let count: int = if a.len() > b.len() { a.len() } else { b.len() }
    var different: int = a.len() ^ b.len()
    for index: int in 0..count {
        let x: int = if index < a.len() { a.get(index) } else { 0 }
        let y: int = if index < b.len() { b.get(index) } else { 0 }
        different = different | (x ^ y)
    }
    return different == 0
}

/// Header-based API key authentication with a non-early-exit comparison.
pub fn api_key(header: string, secret: string) -> Result<
    async fn(HttpContext,
             async fn(HttpContext) -> Result<bool>) -> Result<bool>> {
    if header == "" || secret == "" {
        return err("API key header and secret are required", "config")
    }
    return ok(async fn(context: HttpContext,
                 next: async fn(HttpContext) -> Result<bool>) -> Result<bool> {
        match context.request.headers.get(header) {
            some(presented) => {
                if constant_time_equal(presented, secret) {
                    return await next(context)
                }
            }
            none => {}
        }
        context.response.header("WWW-Authenticate", "ApiKey")
        return write_problem(
            context, 401, "Unauthorized", "A valid API key is required")
    })
}

class WindowState {
    started: int
    count: int = 0

    fn init(started: int) { self.started = started }
}

class FixedWindowLimiter {
    limit: int
    window_nanos: int
    max_clients: int
    clients: Map<string, WindowState> = {}

    fn init(limit: int, window_ms: int, max_clients: int) {
        self.limit = limit
        self.window_nanos = window_ms * 1000000
        self.max_clients = max_clients
    }

    fn prune(now: int) {
        var expired: List<string> = []
        for key: string in self.clients.keys() {
            match self.clients.get(key) {
                some(state) => {
                    if now - state.started >= self.window_nanos {
                        expired.push(key)
                    }
                }
                none => {}
            }
        }
        for key: string in expired { self.clients.remove(key) }
    }

    fn allow(key: string) -> bool {
        let now: int = time.monotonic_nanos()
        var state: WindowState = new WindowState(now)
        match self.clients.get(key) {
            some(found) => { state = found }
            none => {
                if self.clients.len() >= self.max_clients {
                    self.prune(now)
                    if self.clients.len() >= self.max_clients {
                        return false
                    }
                }
            }
        }
        if now - state.started >= self.window_nanos {
            state.started = now
            state.count = 0
        }
        state.count += 1
        self.clients[key] = state
        return state.count <= self.limit
    }
}

/// Per-client fixed-window rate limit middleware.
pub fn fixed_window_rate_limit(limit: int,
                               window_ms: int,
                               max_clients: int = 65536) -> Result<
    async fn(HttpContext,
             async fn(HttpContext) -> Result<bool>) -> Result<bool>> {
    if limit <= 0 || window_ms <= 0 || max_clients <= 0 {
        return err(
            "rate limit, window, and client capacity must be positive",
            "config")
    }
    let limiter: FixedWindowLimiter = new FixedWindowLimiter(
        limit, window_ms, max_clients)
    return ok(async fn(context: HttpContext,
                 next: async fn(HttpContext) -> Result<bool>) -> Result<bool> {
        if limiter.allow(context.request.remote.host) {
            return await next(context)
        }
        context.response.header("Retry-After", "{(window_ms + 999) / 1000}")
        return write_problem(
            context, 429, "Too Many Requests", "Rate limit exceeded")
    })
}
