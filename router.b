package espresso

class Route {
    method: string
    pattern: string
    segments: List<string>
    names: List<string>
    kinds: List<int>
    score: int
    handler: fn(HttpContext) -> Result<ActionResult>

    fn init(method: string,
            pattern: string,
            move segments: List<string>,
            move names: List<string>,
            move kinds: List<int>,
            score: int,
            handler: fn(HttpContext) -> Result<ActionResult>) {
        self.method = method
        self.pattern = pattern
        self.segments = move segments
        self.names = move names
        self.kinds = move kinds
        self.score = score
        self.handler = handler
    }

    fn same_shape(other: Route) -> bool {
        if self.method != other.method ||
           self.kinds.len() != other.kinds.len() {
            return false
        }
        for index: int in 0..self.kinds.len() {
            if self.kinds[index] != other.kinds[index] { return false }
            if self.kinds[index] == 0 &&
               self.segments[index] != other.segments[index] {
                return false
            }
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

fn parsed_route(method: string,
                pattern: string,
                handler: fn(HttpContext) -> Result<ActionResult>) -> Result<Route> {
    if method == "" { return err("a route needs an HTTP method", "route") }
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
        if piece.starts_with("\{") && piece.ends_with("\}") {
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
            if name == "" || name.contains("\{") || name.contains("\}") ||
               name.contains("/") {
                return err("invalid route parameter name", "route")
            }
            if names.contains(name) {
                return err("route parameter {name} appears twice", "route")
            }
            segment = ""
            score += if kind == 1 { 10 } else { 1 }
        } else {
            if piece.contains("\{") || piece.contains("\}") {
                return err("route braces must wrap one whole segment", "route")
            }
            segment = decode_url_component(piece, false)?
            score += 100
        }
        route_segments.push(segment)
        names.push(name)
        kinds.push(kind)
    }
    return ok(new Route(
        method.to_upper(), pattern, move route_segments,
        move names, move kinds, score, handler))
}

/// Method-and-path router with static, parameter, and final catch-all segments.
pub class Router {
    routes: List<Route> = []
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
        var fully_static: bool = true
        for kind: int in route.kinds {
            if kind != 0 { fully_static = false }
        }
        if !fully_static { return }
        let path: string = join_path(route.segments)
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
                    "route {route.method} {pattern} conflicts with {existing.pattern}",
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
            if !route.path_matches(context.request) { continue }
            self.add_allowed(allowed, route.method)
            let method_matches: bool =
                route.method == requested ||
                (requested == "HEAD" && route.method == "GET")
            if method_matches && route.score > best_score {
                best_score = route.score
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
                route.capture_values(context.request)
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
