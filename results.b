// Action results: what a handler returns instead of writing the response.
//
// Every route handler and controller action produces one ActionResult; the
// router executes it against the context after the handler returns. A
// result object is cheap — one small allocation per request — and it is
// the extension point views arrive through later: a template result is
// just one more implementation.
package espresso

import std.encoding.json

/// One computed response, executed by the router after the handler runs.
pub interface ActionResult {
    fn execute(context: HttpContext) -> Result<bool>
}

/// 200/xx text/plain body.
pub class TextResult implements ActionResult {
    status: int
    body: string

    pub fn init(status: int, body: string) {
        self.status = status
        self.body = body
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        context.response.text(
            self.status, reason_for(self.status), self.body)
        return ok(true)
    }
}

/// A body already encoded as JSON text.
pub class JsonTextResult implements ActionResult {
    status: int
    encoded: string

    pub fn init(status: int, encoded: string) {
        self.status = status
        self.encoded = encoded
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        return write_json_text(
            context.response, self.status,
            reason_for(self.status), self.encoded)
    }
}

/// A JSON DOM value, stringified when the result executes.
pub class JsonResult implements ActionResult {
    status: int
    value: json.Value

    pub fn init(status: int, value: json.Value) {
        self.status = status
        self.value = value
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        return write_json(
            context.response, self.status,
            reason_for(self.status), self.value)
    }
}

/// 204, or any other status that carries no body.
pub class NoContentResult implements ActionResult {
    pub fn init() {}

    pub fn execute(context: HttpContext) -> Result<bool> {
        context.response.no_content()
        return ok(true)
    }
}

/// A bare status with its standard reason and no body.
pub class StatusResult implements ActionResult {
    status: int

    pub fn init(status: int) { self.status = status }

    pub fn execute(context: HttpContext) -> Result<bool> {
        context.response.text_body(
            self.status, reason_for(self.status), "", "")
        return ok(true)
    }
}

/// An RFC 9457 problem+json body.
pub class ProblemResult implements ActionResult {
    status: int
    title: string
    detail: string

    pub fn init(status: int, title: string, detail: string) {
        self.status = status
        self.title = title
        self.detail = detail
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        let problem: json.Value = json.Value.object()
        problem.add("status", json.Value.from_int(self.status))?
        problem.add("title", json.Value.from_string(self.title))?
        problem.add("detail", json.Value.from_string(self.detail))?
        problem.add("traceId",
                    json.Value.from_string(context.trace_id()))?
        context.response.text_body(
            self.status, self.title, json.stringify(problem)?,
            "application/problem+json; charset=utf-8")
        return ok(true)
    }
}

/// A response the handler finished by hand, or handed to a Responder via
/// respond_later — executing it changes nothing.
pub class DetachedResult implements ActionResult {
    pub fn init() {}

    pub fn execute(context: HttpContext) -> Result<bool> {
        return ok(true)
    }
}

/// Bytes with an explicit content type.
///
/// The payload is **handed over**, not copied. `init` takes it by `move` and
/// `execute` moves it on into the response, so a megabyte body reaches the
/// socket without ever being duplicated — the last copy issue #5 named.
///
/// That makes a BytesResult single-use: one result answers one request. A
/// second `execute` has no payload left and says so rather than sending an
/// empty body, the same one-shot contract `Responder` keeps. Build one per
/// request; a payload served repeatedly belongs in `text`/`html`, whose
/// `string` is immutable and therefore safe to share.
pub class BytesResult implements ActionResult {
    status: int
    // The payload, parked in a one-slot list rather than held in a plain
    // field. A field of a move-only type cannot be moved out — the language
    // says so and names the way around it: "field and index moves need
    // consuming accessors such as List `remove`" (beans spec/SYNTAX.md).
    // `remove` hands the element's handle out and leaves the slot empty, with
    // no copy of the bytes behind it; a plain field left `execute` no way to
    // give the payload away except `slice`, a full copy of every response.
    slot: List<Bytes> = []
    content_type: string

    pub fn init(status: int, move body: Bytes, content_type: string) {
        self.status = status
        self.slot.push(move body)
        self.content_type = content_type
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        if self.slot.len() == 0 {
            return err(
                "this BytesResult already handed its body to a response; a BytesResult answers one request, so build one per request",
                "result")
        }
        let body: Bytes = self.slot.remove(0)
        context.response.bytes(
            self.status, reason_for(self.status), move body,
            self.content_type)
        return ok(true)
    }
}

/// text/html with the given status.
pub class HtmlResult implements ActionResult {
    status: int
    body: string

    pub fn init(status: int, body: string) {
        self.status = status
        self.body = body
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        context.response.text_body(
            self.status, reason_for(self.status), self.body,
            "text/html; charset=utf-8")
        return ok(true)
    }
}

fn reason_for(status: int) -> string {
    return match status {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        415 => "Unsupported Media Type",
        422 => "Unprocessable Content",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "Status {status}",
    }
}

// ---- the short constructors handlers actually write -----------------------

/// 200 text/plain.
pub fn text(body: string) -> Result<ActionResult> {
    return ok(new TextResult(200, body))
}

pub fn text_status(status: int, body: string) -> Result<ActionResult> {
    return ok(new TextResult(status, body))
}

/// 200 application/json from a DOM value.
pub fn json_value(value: json.Value) -> Result<ActionResult> {
    return ok(new JsonResult(200, value))
}

/// 200 application/json from already-encoded text — pairs with
/// json.encode(typed) for the no-DOM path.
pub fn json_text(encoded: string) -> Result<ActionResult> {
    return ok(new JsonTextResult(200, encoded))
}

pub fn json_text_status(status: int,
                        encoded: string) -> Result<ActionResult> {
    return ok(new JsonTextResult(status, encoded))
}

/// 201 with a Location-less JSON body.
pub fn created_json(encoded: string) -> Result<ActionResult> {
    return ok(new JsonTextResult(201, encoded))
}

pub fn no_content() -> Result<ActionResult> {
    return ok(new NoContentResult())
}

pub fn status(code: int) -> Result<ActionResult> {
    return ok(new StatusResult(code))
}

pub fn not_found() -> Result<ActionResult> {
    return ok(new ProblemResult(
        404, "Not Found", "The requested resource does not exist."))
}

pub fn problem(code: int, title: string,
               detail: string) -> Result<ActionResult> {
    return ok(new ProblemResult(code, title, detail))
}

pub fn html(body: string) -> Result<ActionResult> {
    return ok(new HtmlResult(200, body))
}

/// The handler answered by hand, or armed a Responder.
pub fn detached() -> Result<ActionResult> {
    return ok(new DetachedResult())
}
