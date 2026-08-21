package espresso

import std.http
import std.net

/// Stable response copy returned by the in-memory test host.
pub class TestResponse {
    pub status: int
    pub reason: string
    pub headers: http.Headers
    pub body: Bytes
    pub trace_id: string

    fn init(context: HttpContext) {
        self.status = context.response.status
        self.reason = context.response.reason
        self.headers = context.response.headers
        self.body = context.response.body.slice(
            0, context.response.body.len())
        self.trace_id = context.trace_id()
    }

    pub fn text() -> string { return self.body.to_string() }
}

/// Runs the full app pipeline without opening a socket.
pub class TestHost {
    app: WebApplication
    closed: bool = false

    pub fn init(app: WebApplication) { self.app = app }

    pub fn send(method: string,
                target: string,
                body: string = "") -> Result<TestResponse> {
        return self.send_with_headers(
            method, target, new http.Headers(), body)
    }

    pub fn send_with_headers(method: string,
                             target: string,
                             headers: http.Headers,
                             body: string = "") -> Result<TestResponse> {
        if self.closed { return err("the test host is closed", "closed") }
        let served: http.ServedRequest = new http.ServedRequest()
        served.head.method = method
        served.head.target = target
        served.head.headers = headers
        served.body = Bytes.from(body)
        let context: HttpContext = self.app.handle(
            served, new net.Address("127.0.0.1", 1))?
        let response: TestResponse = new TestResponse(context)
        context.close()?
        return ok(response)
    }

    pub fn get(target: string) -> Result<TestResponse> {
        return self.send("GET", target)
    }

    pub fn post(target: string, body: string = "") -> Result<TestResponse> {
        return self.send("POST", target, body)
    }

    pub fn close() -> Result<bool> {
        if self.closed { return err("the test host is closed", "closed") }
        self.closed = true
        return self.app.close()
    }
}
