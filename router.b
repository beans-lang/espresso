package espresso

import std.http
import std.net

// The path half of a route, without the method or the handler: the parsed
// segments, the parameter names, what each segment is (0 literal,
// 1 parameter, 2 catch-all) and the specificity score.
//
// It sits in its own class because two tables share it. An ordinary route is
// a method plus this plus a handler; an upgrade endpoint is this plus an
// upgrade handler, matched only when the parser says the client asked to
// switch protocols. Two copies of segment matching would drift, and the copy
// nobody reads is the one that would.
class RoutePattern {
    pattern: string
    segments: List<string>
    names: List<string>
    kinds: List<int>
    score: int

    fn init(pattern: string,
            move segments: List<string>,
            move names: List<string>,
            move kinds: List<int>,
            score: int) {
        self.pattern = pattern
        self.segments = move segments
        self.names = move names
        self.kinds = move kinds
        self.score = score
    }

    // Two patterns match the same set of paths: same shape, same literals.
    // Parameter names do not matter — `/a/{id}` and `/a/{key}` are the same
    // route written twice.
    fn same_shape(other: RoutePattern) -> bool {
        if self.kinds.len() != other.kinds.len() { return false }
        for index: int in 0..self.kinds.len() {
            if self.kinds[index] != other.kinds[index] { return false }
            if self.kinds[index] == 0 &&
               self.segments[index] != other.segments[index] {
                return false
            }
        }
        return true
    }

    fn is_static() -> bool {
        for kind: int in self.kinds {
            if kind != 0 { return false }
        }
        return true
    }

    fn path_matches(request: HttpRequest) -> bool {
        var request_index: int = 0
        for route_index: int in 0..self.kinds.len() {
            let kind: int = self.kinds[route_index]
            if kind == 2 {
                return true
            }
            if request_index >= request.segments_cache.len() { return false }
            if kind == 0 {
                if self.segments[route_index] !=
                       request.segments_cache[request_index] {
                    return false
                }
            }
            request_index += 1
        }
        return request_index == request.segments_cache.len()
    }

    fn capture_values(request: HttpRequest) {
        var request_index: int = 0
        for route_index: int in 0..self.kinds.len() {
            let kind: int = self.kinds[route_index]
            if kind == 2 {
                var rest: List<string> = []
                for index: int in request_index..request.segments_cache.len() {
                    rest.push(request.segments_cache[index])
                }
                request.route_values[self.names[route_index]] = rest.join("/")
                return
            }
            if kind == 1 {
                request.route_values[self.names[route_index]] =
                    request.segments_cache[request_index]
            }
            request_index += 1
        }
    }
}

class Route {
    method: string
    shape: RoutePattern
    handler: fn(HttpContext) -> Result<ActionResult>

    fn init(method: string,
            shape: RoutePattern,
            handler: fn(HttpContext) -> Result<ActionResult>) {
        self.method = method
        self.shape = shape
        self.handler = handler
    }

    fn same_shape(other: Route) -> bool {
        if self.method != other.method { return false }
        return self.shape.same_shape(other.shape)
    }
}

/// One protocol-upgrade endpoint: a handler that is given the connection
/// itself, not a response to fill in.
///
/// It is an interface and not a function because a function type in Beans
/// cannot declare a `move` parameter, and because an upgrade handler almost
/// always carries state — a registry of live sockets, a configuration — the
/// way `Middleware` does.
///
/// `upgrade` is called only after the middleware pipeline has run and let the
/// request through, so authentication, cookies and an `Origin` check apply to
/// a handshake exactly as they do to a request. By the time it is called the
/// connection fiber has given up the socket: it will not read it, write it,
/// or close it again, and this handler owns it for the rest of its life.
/// `request` is the raw parsed head, which is what `websocket.accept_websocket`
/// needs — the handshake fields, the HTTP version and the method live there
/// and not on `HttpContext.request`. It is valid for the duration of the call.
///
/// Returning an error ends the connection and is recorded server-side; there
/// is no way to answer with a status, because the socket is gone.
///
/// **The socket arrives registered with this worker's fiber netpoller, and
/// every read on it parks the fiber rather than holding the thread.** That
/// holds for `read`, `read_exact` and `read_into` alike, so a handler that
/// waits — for the next WebSocket frame, for the next line — costs one parked
/// fiber and leaves the worker free for every other connection on it. Two
/// upgraded connections on one worker are served concurrently, which
/// tests/upgrade.b measures rather than assumes: a handler that waits 900ms is
/// overtaken by one that arrives 200ms later and waits 100ms.
///
/// The handler runs on a child fiber, so a panic inside it is contained: it
/// ends this one connection, is recorded server-side, and the server keeps
/// accepting.
pub interface UpgradeHandler {
    fn upgrade(context: HttpContext,
               request: http.Request,
               move stream: net.TcpStream) -> Result<bool>
}

class UpgradeRoute {
    shape: RoutePattern
    handler: UpgradeHandler

    fn init(shape: RoutePattern, handler: UpgradeHandler) {
        self.shape = shape
        self.handler = handler
    }
}

fn parsed_pattern(pattern: string) -> Result<RoutePattern> {
    if pattern == "" || !pattern.starts_with("/") {
        return err("a route pattern must start with /", "route")
    }
    if pattern.find("?").is_some() || pattern.find("#").is_some() {
        return err("a route pattern cannot contain a query or fragment", "route")
    }
    var route_segments: List<string> = []
    var names: List<string> = []
    var kinds: List<int> = []
    var score: int = 0
    let pieces: List<string> = pattern.split("/")
    for index: int in 1..pieces.len() {
        let piece: string = pieces[index]
        if index == pieces.len() - 1 && piece == "" { continue }
        var kind: int = 0
        var name: string = ""
        var segment: string = piece
        if piece.starts_with(r"{") && piece.ends_with(r"}") {
            if piece.len() <= 2 {
                return err("a route parameter needs a name", "route")
            }
            name = piece.slice(1, piece.len() - 1)
            kind = 1
            if name.starts_with("*") {
                name = name.slice(1, name.len())
                kind = 2
                if index != pieces.len() - 1 {
                    return err("a catch-all route parameter must be last", "route")
                }
            }
            if name == "" || name.contains(r"{") || name.contains(r"}") ||
               name.contains("/") {
                return err("invalid route parameter name", "route")
            }
            if names.contains(name) {
                return err("route parameter {name} appears twice", "route")
            }
            segment = ""
            score += if kind == 1 { 10 } else { 1 }
        } else {
            if piece.contains(r"{") || piece.contains(r"}") {
                return err("route braces must wrap one whole segment", "route")
            }
            segment = decode_url_component(piece, false)?
            score += 100
        }
        route_segments.push(segment)
        names.push(name)
        kinds.push(kind)
    }
    return ok(new RoutePattern(
        pattern, move route_segments, move names, move kinds, score))
}

fn parsed_route(method: string,
                pattern: string,
                handler: fn(HttpContext) -> Result<ActionResult>) -> Result<Route> {
    if method == "" { return err("a route needs an HTTP method", "route") }
    return ok(new Route(
        method.to_upper(), parsed_pattern(pattern)?, handler))
}

/// Method-and-path router with static, parameter, and final catch-all segments.
pub class Router {
    routes: List<Route> = []
    // Upgrade endpoints live in their own table and are reachable only from
    // dispatch_upgrade — a plain GET to an upgrade path must not reach a
    // handler that expects to be handed a socket, and an ordinary route may
    // share the path with one. There is no static-path index here on purpose:
    // an upgrade happens once per connection, not once per request, so a
    // linear scan is never the cost that matters and a second index is a
    // second thing to keep in step.
    upgrades: List<UpgradeRoute> = []
    static_get: Map<string, int> = {}
    static_post: Map<string, int> = {}
    static_put: Map<string, int> = {}
    static_patch: Map<string, int> = {}
    static_delete: Map<string, int> = {}
    static_other: Map<string, int> = {}

    pub fn init() {}

    other_static_count: int = 0

    fn static_lookup(method: string, path: string) -> Option<int> {
        if method == "GET" { return self.static_get.get(path) }
        if method == "POST" { return self.static_post.get(path) }
        if method == "PUT" { return self.static_put.get(path) }
        if method == "PATCH" { return self.static_patch.get(path) }
        if method == "DELETE" { return self.static_delete.get(path) }
        if self.other_static_count == 0 { return none }
        return self.static_other.get("{method} {path}")
    }

    fn index_static(route: Route, index: int) {
        if !route.shape.is_static() { return }
        let path: string = join_path(route.shape.segments)
        if route.method == "GET" { self.static_get[path] = index }
        else if route.method == "POST" { self.static_post[path] = index }
        else if route.method == "PUT" { self.static_put[path] = index }
        else if route.method == "PATCH" { self.static_patch[path] = index }
        else if route.method == "DELETE" { self.static_delete[path] = index }
        else {
            self.static_other["{route.method} {path}"] = index
            self.other_static_count += 1
        }
    }

    pub fn map(method: string,
               pattern: string,
               handler: fn(HttpContext) -> Result<ActionResult>) -> Result<bool> {
        let route: Route = parsed_route(method, pattern, handler)?
        for existing: Route in self.routes {
            if existing.same_shape(route) {
                return err(
                    "route {route.method} {pattern} conflicts with {existing.shape.pattern}",
                    "route_conflict")
            }
        }
        self.index_static(route, self.routes.len())
        self.routes.push(route)
        return ok(true)
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

    /// Registers a protocol-upgrade endpoint. Patterns are the ordinary route
    /// patterns, parameters and catch-all included, and they are captured into
    /// `request.route_values` before the handler runs.
    ///
    /// There is no method: RFC 6455 requires GET for a WebSocket handshake and
    /// `accept_websocket` enforces it, and another protocol may reasonably
    /// upgrade from something else. What selects this table is the client
    /// asking to switch protocols, not the verb.
    pub fn map_upgrade(pattern: string,
                       handler: UpgradeHandler) -> Result<bool> {
        let shape: RoutePattern = parsed_pattern(pattern)?
        for existing: UpgradeRoute in self.upgrades {
            if existing.shape.same_shape(shape) {
                return err(
                    "upgrade endpoint {pattern} conflicts with {existing.shape.pattern}",
                    "route_conflict")
            }
        }
        self.upgrades.push(new UpgradeRoute(shape, handler))
        return ok(true)
    }

    /// The pipeline terminal for a request that asked to switch protocols.
    ///
    /// It selects the most specific matching upgrade endpoint, records it on
    /// the context and writes nothing — the connection fiber reads the
    /// selection afterwards and hands the socket over. When nothing matches it
    /// answers 400, because the parser has already stopped and this connection
    /// can no longer carry an ordinary request: there is no "ignore the
    /// Upgrade header and serve it normally" left to fall back to.
    fn dispatch_upgrade(context: HttpContext) -> Result<bool> {
        context.request.ensure_segments()?
        var best_score: int = -1
        var selected: Option<UpgradeRoute> = none
        for route: UpgradeRoute in self.upgrades {
            if !route.shape.path_matches(context.request) { continue }
            if route.shape.score > best_score {
                best_score = route.shape.score
                selected = some(route)
            }
        }
        match selected {
            some(route) => {
                route.shape.capture_values(context.request)
                context.select_upgrade(route.handler)
                return ok(true)
            }
            none => {}
        }
        return write_problem(
            context, 400, "Bad Request",
            "No endpoint at {context.request.path} speaks a protocol upgrade")
    }

    fn add_allowed(allowed: List<string>, method: string) {
        if !allowed.contains(method) { allowed.push(method) }
        if method == "GET" && !allowed.contains("HEAD") {
            allowed.push("HEAD")
        }
    }

    fn dispatch(context: HttpContext) -> Result<bool> {
        let requested: string = context.request.method

        // Fast path: a literal request path hitting a fully static route on
        // its exact method (HEAD borrows GET). No decoding, no allocation.
        if context.request.plain_path() && requested != "OPTIONS" {
            var hit: Option<int> =
                self.static_lookup(requested, context.request.path)
            if hit.is_none() && requested == "HEAD" {
                hit = self.static_get.get(context.request.path)
            }
            match hit {
                some(index) => {
                    context.head_only = requested == "HEAD"
                    let route: Route = self.routes[index]
                    let produced: ActionResult = route.handler(context)?
                    return produced.execute(context)
                }
                none => {}
            }
        }

        context.request.ensure_segments()?
        var best_score: int = -1
        var selected: Option<Route> = none
        var allowed: List<string> = []

        for route: Route in self.routes {
            if !route.shape.path_matches(context.request) { continue }
            self.add_allowed(allowed, route.method)
            let method_matches: bool =
                route.method == requested ||
                (requested == "HEAD" && route.method == "GET")
            if method_matches && route.shape.score > best_score {
                best_score = route.shape.score
                selected = some(route)
            }
        }

        if requested == "OPTIONS" && allowed.len() != 0 {
            if !allowed.contains("OPTIONS") { allowed.push("OPTIONS") }
            allowed.sort()
            context.response.header("Allow", allowed.join(", "))
            context.response.no_content()
            return ok(true)
        }

        match selected {
            some(route) => {
                route.shape.capture_values(context.request)
                context.head_only = requested == "HEAD"
                let produced: ActionResult = route.handler(context)?
                return produced.execute(context)
            }
            none => {}
        }

        if allowed.len() != 0 {
            allowed.sort()
            context.response.header("Allow", allowed.join(", "))
            return write_problem(
                context, 405, "Method Not Allowed",
                "No endpoint accepts {requested} for {context.request.path}")
        }
        return write_problem(
            context, 404, "Not Found",
            "No endpoint matches {context.request.path}")
    }
}
