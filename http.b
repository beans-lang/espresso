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
    let source: Bytes = Bytes.from(text)
    let target: Bytes = new Bytes(0)
    target.reserve(source.len())
    var index: int = 0
    for index < source.len() {
        let byte: int = source.get(index)
        if byte == 37 {
            if index + 2 >= source.len() {
                return err("incomplete percent escape in request target", "bad_request")
            }
            let high: int = hex_value(source.get(index + 1))
            let low: int = hex_value(source.get(index + 2))
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
            if byte == 0 || byte < 32 || byte == 127 {
                return err("request target contains a control byte", "bad_request")
            }
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

fn parse_query(text: string) -> Result<QueryValues> {
    let result: QueryValues = new QueryValues()
    if text == "" { return ok(result) }
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
    return ok(result)
}

fn request_path(target: string) -> Result<List<string>> {
    if target == "" || !target.starts_with("/") {
        return err("the request target must use origin form", "bad_request")
    }
    var raw_path: string = target
    match target.find("?") {
        some(at) => { raw_path = target.slice(0, at) }
        none => {}
    }
    if raw_path.find("#").is_some() {
        return err("a request target cannot contain a fragment", "bad_request")
    }
    var segments: List<string> = []
    let pieces: List<string> = raw_path.split("/")
    for index: int in 1..pieces.len() {
        // A trailing slash is normalized away. Empty segments in the middle
        // remain visible, so `/a//b` does not silently become `/a/b`.
        if index == pieces.len() - 1 && pieces[index] == "" { continue }
        segments.push(decode_url_component(pieces[index], false)?)
    }
    return ok(move segments)
}

fn join_path(segments: List<string>) -> string {
    if segments.len() == 0 { return "/" }
    return "/{segments.join("/")}"
}

/// One request as Espresso presents it to middleware and endpoints.
pub class HttpRequest {
    pub method: string
    pub target: string
    pub path: string
    pub segments: List<string>
    pub query: QueryValues
    pub headers: http.Headers
    pub body: Bytes
    pub route_values: Map<string, string> = {}
    pub remote: net.Address
    pub keep_alive: bool

    fn init(served: http.ServedRequest,
            remote: net.Address,
            move parsed_segments: List<string>,
            parsed_query: QueryValues) {
        self.method = served.head.method
        self.target = served.head.target
        self.segments = move parsed_segments
        self.path = join_path(self.segments)
        self.query = parsed_query
        self.headers = served.head.headers
        self.body = served.body.slice(0, served.body.len())
        self.remote = remote
        self.keep_alive = served.keep_alive
    }

    pub static fn from_served(served: http.ServedRequest,
                              remote: net.Address) -> Result<HttpRequest> {
        let segments: List<string> = request_path(served.head.target)?
        var query_text: string = ""
        match served.head.target.find("?") {
            some(at) => {
                query_text = served.head.target.slice(
                    at + 1, served.head.target.len())
            }
            none => {}
        }
        let query: QueryValues = parse_query(query_text)?
        return ok(new HttpRequest(
            served, remote, move segments, query))
    }

    pub fn route(name: string) -> Option<string> {
        return self.route_values.get(name)
    }
}

/// A buffered HTTP response. The server owns Content-Length and Connection.
pub class HttpResponse {
    pub status: int = 200
    pub reason: string = "OK"
    pub headers: http.Headers = new http.Headers()
    pub body: Bytes = new Bytes(0)
    pub completed: bool = false

    pub fn init() {}

    pub fn header(name: string, value: string) {
        self.headers.add(name, value)
    }

    pub fn bytes(status: int, reason: string,
                 move body: Bytes,
                 content_type: string = "application/octet-stream") {
        self.status = status
        self.reason = reason
        self.body = move body
        if content_type != "" && !self.headers.has("Content-Type") {
            self.headers.add("Content-Type", content_type)
        }
        self.completed = true
    }

    pub fn text(status: int, reason: string, body: string) {
        self.bytes(status, reason, Bytes.from(body),
                   "text/plain; charset=utf-8")
    }

    pub fn no_content() {
        self.status = 204
        self.reason = "No Content"
        self.body = new Bytes(0)
        self.completed = true
    }
}

/// Per-request state shared by middleware and the chosen endpoint.
pub class HttpContext {
    pub request: HttpRequest
    pub response: HttpResponse = new HttpResponse()
    pub services: ServiceProvider
    pub trace_id: string
    pub head_only: bool = false

    pub fn init(request: HttpRequest,
                services: ServiceProvider,
                trace_id: string) {
        self.request = request
        self.services = services
        self.trace_id = trace_id
    }

    pub fn close() -> Result<bool> {
        return self.services.close()
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
    response.bytes(status, reason, Bytes.from(encoded),
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
    problem.add("traceId", json.Value.from_string(context.trace_id))?
    context.response.bytes(
        status, title, Bytes.from(json.stringify(problem)?),
        "application/problem+json; charset=utf-8")
    return ok(true)
}
