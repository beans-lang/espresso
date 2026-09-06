package espresso

import std.encoding.json
import std.http
import std.net

/// Query fields in arrival order. Repeated names stay repeated.
pub class QueryValues {
    names: List<string> = []
    values: List<string> = []

    pub fn init() {}

    pub fn add(name: string, value: string) {
        self.names.push(name)
        self.values.push(value)
    }

    fn clear() {
        self.names.clear()
        self.values.clear()
    }

    pub fn count() -> int { return self.names.len() }

    pub fn get(name: string) -> Option<string> {
        for index: int in 0..self.names.len() {
            if self.names[index] == name { return some(self.values[index]) }
        }
        return none
    }

    pub fn all(name: string) -> List<string> {
        var result: List<string> = []
        for index: int in 0..self.names.len() {
            if self.names[index] == name { result.push(self.values[index]) }
        }
        return move result
    }

    pub fn name_at(index: int) -> string { return self.names[index] }
    pub fn value_at(index: int) -> string { return self.values[index] }
}

fn hex_value(byte: int) -> int {
    if byte >= 48 && byte <= 57 { return byte - 48 }
    if byte >= 65 && byte <= 70 { return byte - 65 + 10 }
    if byte >= 97 && byte <= 102 { return byte - 97 + 10 }
    return -1
}

fn decode_url_component(text: string, plus_as_space: bool) -> Result<string> {
    var needs_decode: bool = false
    var checked: int = 0
    for checked < text.len() {
        let byte: int = text.byte_at(checked)
        if byte == 37 || (plus_as_space && byte == 43) {
            needs_decode = true
        }
        if byte == 0 || byte < 32 || byte == 127 {
            return err("request target contains a control byte", "bad_request")
        }
        checked += 1
    }
    if !needs_decode { return ok(text) }

    let target: Bytes = new Bytes(0)
    target.reserve(text.len())
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte == 37 {
            if index + 2 >= text.len() {
                return err("incomplete percent escape in request target", "bad_request")
            }
            let high: int = hex_value(text.byte_at(index + 1))
            let low: int = hex_value(text.byte_at(index + 2))
            if high < 0 || low < 0 {
                return err("invalid percent escape in request target", "bad_request")
            }
            let decoded: int = high * 16 + low
            if decoded == 0 || decoded < 32 || decoded == 127 {
                return err("request target contains a control byte", "bad_request")
            }
            target.push(decoded)
            index += 3
        } else {
            if plus_as_space && byte == 43 {
                target.push(32)
            } else {
                target.push(byte)
            }
            index += 1
        }
    }
    return ok(target.to_string())
}

fn parse_query_into(text: string, result: QueryValues) -> Result<bool> {
    result.clear()
    if text == "" { return ok(true) }
    for pair: string in text.split("&") {
        var name: string = pair
        var value: string = ""
        match pair.find("=") {
            some(at) => {
                name = pair.slice(0, at)
                value = pair.slice(at + 1, pair.len())
            }
            none => {}
        }
        result.add(
            decode_url_component(name, true)?,
            decode_url_component(value, true)?)
    }
    return ok(true)
}

fn split_path_into(raw_path: string, segments: List<string>) -> Result<bool> {
    segments.clear()
    if raw_path == "" || !raw_path.starts_with("/") {
        return err("the request target must use origin form", "bad_request")
    }
    if raw_path.find("#").is_some() {
        return err("a request target cannot contain a fragment", "bad_request")
    }
    var start: int = 1
    for start <= raw_path.len() {
        var end: int = raw_path.find_byte(47, start)
        if end < 0 { end = raw_path.len() }
        // A trailing slash is normalized away. Empty segments in the middle
        // remain visible, so `/a//b` does not silently become `/a/b`.
        if start == raw_path.len() { break }
        segments.push(decode_url_component(
            raw_path.slice(start, end), false)?)
        if end == raw_path.len() { break }
        start = end + 1
    }
    return ok(true)
}

fn join_path(segments: List<string>) -> string {
    if segments.len() == 0 { return "/" }
    return "/{segments.join("/")}"
}

/// One request as Espresso presents it to middleware and endpoints. The
/// server reuses one instance for every request on a connection, so a
/// handler that wants request data beyond its own return must copy it.
pub unique class HttpRequest {
    pub method: string = ""
    pub target: string = ""
    /// The raw request path: the target up to `?`, undecoded.
    pub path: string = "/"
    pub headers: http.Headers = new http.Headers()
    pub body: Bytes = new Bytes(0)
    pub trailer_fields: http.Headers = new http.Headers()
    pub route_values: Map<string, string> = {}
    pub remote: net.Address
    pub keep_alive: bool = true
    query_start: int = -1
    path_plain: bool = true
    segments_cache: List<string> = []
    segments_ready: bool = false
    query_cache: QueryValues = new QueryValues()
    query_ready: bool = false

    fn init(remote: net.Address) {
        self.remote = remote
    }

    /// Resets this request in place around a freshly parsed head. The body
    /// arrives afterwards through `body` events.
    fn begin(head: http.Request) -> Result<bool> {
        self.method = head.method
        self.target = head.target
        self.headers = head.headers
        self.keep_alive = head.keep_alive
        self.body.resize(0)
        if self.trailer_fields.count() != 0 {
            self.trailer_fields = new http.Headers()
        }
        self.route_values.clear()
        self.segments_ready = false
        self.query_ready = false
        if head.target == "" || head.target.byte_at(0) != 47 {
            return err("the request target must use origin form", "bad_request")
        }
        match head.target.find("?") {
            some(at) => {
                self.path = head.target.slice(0, at)
                self.query_start = at + 1
            }
            none => {
                self.path = head.target
                self.query_start = -1
            }
        }
        var plain: bool = true
        var index: int = 0
        for index < self.path.len() {
            let byte: int = self.path.byte_at(index)
            if byte == 37 || byte == 35 {
                plain = false
                break
            }
            index += 1
        }
        self.path_plain = plain
        return ok(true)
    }

    /// True when `path` needs no percent-decoding to compare literally.
    fn plain_path() -> bool { return self.path_plain }

    fn ensure_segments() -> Result<bool> {
        if self.segments_ready { return ok(true) }
        split_path_into(self.path, self.segments_cache)?
        self.segments_ready = true
        return ok(true)
    }

    /// Decoded path segments. `/users/42` yields `users`, `42`.
    pub fn segment_count() -> Result<int> {
        self.ensure_segments()?
        return ok(self.segments_cache.len())
    }

    pub fn segment_at(index: int) -> Result<string> {
        self.ensure_segments()?
        return ok(self.segments_cache[index])
    }

    /// The decoded path, one segment per slash, rebuilt canonically.
    pub fn decoded_path() -> Result<string> {
        self.ensure_segments()?
        return ok(join_path(self.segments_cache))
    }

    /// Query fields, parsed on first use and cached for this request.
    pub fn query() -> Result<QueryValues> {
        if self.query_ready { return ok(self.query_cache) }
        var text: string = ""
        if self.query_start >= 0 {
            text = self.target.slice(self.query_start, self.target.len())
        }
        parse_query_into(text, self.query_cache)?
        self.query_ready = true
        return ok(self.query_cache)
    }

    pub fn route(name: string) -> Option<string> {
        return self.route_values.get(name)
    }
}

/// A buffered HTTP response. The server owns Content-Length and Connection.
///
/// The response holds the handler's payload by reference, not by copy: a
/// `string` body is kept as the handler's own string (`body_text`) and a
/// `Bytes` body is moved in (`body`). The server frames the head from the
/// payload's length and either appends a small payload to its output queue or
/// sends a large one beside the head with one vectored write — the payload
/// never grows a per-connection buffer, which is what kept a megabyte alive on
/// every connection before (see beans-lang/beans#140).
///
/// `body` is the bytes-form payload and is empty when the payload is a string;
/// `body_bytes()` returns the payload as bytes regardless of form.
pub unique class HttpResponse {
    pub status: int = 200
    pub reason: string = "OK"
    pub headers: http.Headers = new http.Headers()
    pub body: Bytes = new Bytes(0)
    // The string-form payload, referenced (not copied) from the handler's own
    // string. Empty when the payload is a Bytes.
    body_text: string = ""
    // Which form carries the payload this response.
    body_is_text: bool = false
    pub completed: bool = false

    pub fn init() {}

    fn reset() {
        self.status = 200
        self.reason = "OK"
        if self.headers.count() != 0 { self.headers.clear() }
        // Drop both forms' payloads. A string reference costs nothing to drop;
        // a bytes payload is released outright rather than kept as capacity —
        // resize(0) would leave a megabyte of it resident on an idle
        // connection, which is the retention this class exists to avoid. A
        // response that carried no bytes payload keeps its empty buffer, so the
        // common text path allocates nothing here.
        self.body_text = ""
        if self.body.len() != 0 { self.body = new Bytes(0) }
        self.body_is_text = false
        self.completed = false
    }

    pub fn header(name: string, value: string) {
        self.headers.add(name, value)
    }

    /// Finishes the response with a `Bytes` body, moved in without a copy.
    pub fn bytes(status: int, reason: string,
                 move body: Bytes,
                 content_type: string = "application/octet-stream") {
        self.status = status
        self.reason = reason
        self.body = move body
        self.body_text = ""
        self.body_is_text = false
        if content_type != "" && !self.headers.has("Content-Type") {
            self.headers.add("Content-Type", content_type)
        }
        self.completed = true
    }

    /// Finishes the response with a `string` body, held by reference — no copy
    /// into a response buffer, so a large body never becomes a per-connection
    /// allocation.
    pub fn text_body(status: int, reason: string,
                     body: string, content_type: string) {
        self.status = status
        self.reason = reason
        self.body_text = body
        self.body_is_text = true
        if self.body.len() != 0 { self.body = new Bytes(0) }
        if content_type != "" && !self.headers.has("Content-Type") {
            self.headers.add("Content-Type", content_type)
        }
        self.completed = true
    }

    pub fn text(status: int, reason: string, body: string) {
        self.text_body(status, reason, body, "text/plain; charset=utf-8")
    }

    pub fn no_content() {
        self.status = 204
        self.reason = "No Content"
        self.body_text = ""
        if self.body.len() != 0 { self.body = new Bytes(0) }
        self.body_is_text = false
        self.completed = true
    }

    /// True when the payload is a string (`body` is then empty).
    pub fn is_text_body() -> bool { return self.body_is_text }

    /// The string-form payload, or "" for a bytes body. A cheap reference.
    pub fn text_payload() -> string { return self.body_text }

    /// The payload's length in bytes, in either form.
    pub fn body_len() -> int {
        return if self.body_is_text {
            self.body_text.len()
        } else {
            self.body.len()
        }
    }

    /// The payload materialised as a fresh `Bytes`, whichever form it is in.
    /// For inspecting a finished response (the in-memory test host); not on the
    /// server's send path, which never materialises a string payload.
    pub fn body_bytes() -> Bytes {
        if self.body_is_text {
            let out: Bytes = new Bytes(0)
            out.reserve(self.body_text.len())
            out.append_string(self.body_text)
            return move out
        }
        return self.body.slice(0, self.body.len())
    }
}

/// Per-request state shared by middleware and the chosen endpoint. The
/// server keeps one context per connection and resets it between requests.
pub class HttpContext {
    pub request: HttpRequest
    pub response: HttpResponse = new HttpResponse()
    pub services: ServiceProvider
    pub head_only: bool = false
    root_services: ServiceProvider
    scope_active: bool = false
    trace_seq: int = 0
    trace_text: string = ""
    // True only under the espresso server loop; respond_later refuses
    // everywhere else (a TestHost request has no connection to defer).
    armed: bool = false
    reply: Option<Channel<Completion>> = none
    deferred: bool = false

    pub fn init(move request: HttpRequest,
                services: ServiceProvider) {
        self.request = move request
        self.services = services
        self.root_services = services
    }

    /// A stable id for logs, formatted on first use.
    pub fn trace_id() -> string {
        if self.trace_text == "" && self.trace_seq != 0 {
            self.trace_text = "espresso-{self.trace_seq}"
        }
        return self.trace_text
    }

    fn begin(head: http.Request, sequence: int) -> Result<bool> {
        self.response.reset()
        self.head_only = false
        self.trace_seq = sequence
        self.trace_text = ""
        self.deferred = false
        self.reply = none
        return self.request.begin(head)
    }

    // The connection fiber arms its context once; the flag is all
    // `respond_later` needs now that the reply channel is per-request.
    fn arm_serving() {
        self.armed = true
    }

    // The connection fiber takes the reply channel to wait on it; taking it
    // resets the slot so the next request starts clean.
    fn take_reply() -> Option<Channel<Completion>> {
        let taken: Option<Channel<Completion>> = self.reply
        self.reply = none
        return taken
    }

    /// Marks this request deferred and returns the move-only, Send handle
    /// that finishes it from any thread. The connection fiber waits until
    /// the responder answers or the pending timeout fires, so response order
    /// stays safe even under pipelining. One responder per request.
    pub fn respond_later() -> Result<Responder> {
        if self.deferred {
            return err("this request already has a responder", "deferred")
        }
        if !self.armed {
            return err(
                "deferred responses need the espresso server loop",
                "deferred")
        }
        self.deferred = true
        let reply: Channel<Completion> = new Channel(1)
        self.reply = some(reply)
        return ok(new Responder(reply))
    }

    fn open_scope() -> Result<bool> {
        if self.root_services.has_registrations() {
            self.services = self.root_services.create_scope()?
            self.scope_active = true
        }
        return ok(true)
    }

    /// Closes the request's service scope, if one was opened.
    pub fn close() -> Result<bool> {
        if self.scope_active {
            self.scope_active = false
            let scope: ServiceProvider = self.services
            self.services = self.root_services
            return scope.close_scope()
        }
        return ok(true)
    }
}

/// Parses the buffered request body as JSON. Typed endpoints can call
/// `json.decode_bytes` directly when they want a struct.
pub fn body_json(request: HttpRequest) -> Result<json.Value> {
    return json.parse_bytes(request.body)
}

/// Writes a JSON DOM value. Typed endpoints can pass `json.encode(value)`
/// through `write_json_text` without building a DOM.
pub fn write_json(response: HttpResponse,
                  status: int,
                  reason: string,
                  value: json.Value) -> Result<bool> {
    return write_json_text(
        response, status, reason, json.stringify(value)?)
}

pub fn write_json_text(response: HttpResponse,
                       status: int,
                       reason: string,
                       encoded: string) -> Result<bool> {
    response.text_body(status, reason, encoded,
                       "application/json; charset=utf-8")
    return ok(true)
}

fn write_problem(context: HttpContext,
                 status: int,
                 title: string,
                 detail: string) -> Result<bool> {
    let problem: json.Value = json.Value.object()
    problem.add("status", json.Value.from_int(status))?
    problem.add("title", json.Value.from_string(title))?
    problem.add("detail", json.Value.from_string(detail))?
    problem.add("traceId", json.Value.from_string(context.trace_id()))?
    context.response.text_body(
        status, title, json.stringify(problem)?,
        "application/problem+json; charset=utf-8")
    return ok(true)
}
