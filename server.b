package espresso

import std.calendar
import std.http
import std.net
import std.thread
import std.time

// The graceful sweep pokes parked connection fibers awake through the raw
// descriptor: SHUT_RD turns their next read into EOF without racing the
// fiber that owns the socket. Ledger discipline keeps the fd valid — a
// fiber unregisters before it closes, and both run on the worker thread.
extern "C" fn shutdown(fd: int, how: int) -> i32

// The body size at which a response stops being copied into the output queue
// and is sent beside its head instead.
//
// Below it, copying is cheaper than the write it would save, and appending
// keeps pipelined responses batched into one send. Above it, the copy is the
// dominant cost of the response: a megabyte copied twice is more time than
// everything else the server does for that request put together.
const vectored_body_min: int = 16384

/// Bounds for the listener, parser, connections, bodies, and output queues.
pub class ServerOptions {
    pub host: string = "127.0.0.1"
    pub port: int = 8080
    pub backlog: int = 512
    pub max_connections: int = 10000
    pub max_events: int = 256
    /// How quickly the accept loop notices `control().stop()` and reaps
    /// finished connections when no client is connecting.
    pub poll_timeout_ms: int = 25
    pub idle_timeout_ms: int = 30000
    pub graceful_shutdown_ms: int = 10000
    /// How long a deferred request may stay unanswered before the server
    /// replies 503 and closes the connection.
    pub pending_timeout_ms: int = 30000
    pub read_buffer_bytes: int = 65536
    pub max_body_bytes: int = 8388608
    pub max_response_body_bytes: int = 16777216
    pub max_pending_output_bytes: int = 33554432
    pub max_requests_per_connection: int = 1000000
    pub max_header_count: int = 128
    pub max_header_bytes: int = 65536
    pub max_target_bytes: int = 8192
    pub max_head_span_bytes: int = 16384

    pub fn init() {}

    fn validate() -> Result<bool> {
        if self.host == "" { return err("server host is required", "config") }
        if self.port < 0 || self.port > 65535 {
            return err("server port must be 0..65535", "config")
        }
        if self.backlog <= 0 || self.max_connections <= 0 ||
           self.max_events <= 0 || self.poll_timeout_ms < 0 ||
           self.idle_timeout_ms <= 0 || self.graceful_shutdown_ms < 0 ||
           self.pending_timeout_ms <= 0 ||
           self.read_buffer_bytes <= 0 || self.max_body_bytes <= 0 ||
           self.max_response_body_bytes <= 0 ||
           self.max_pending_output_bytes <= 0 ||
           self.max_requests_per_connection <= 0 ||
           self.max_header_count <= 0 || self.max_header_bytes <= 0 ||
           self.max_target_bytes <= 0 || self.max_head_span_bytes <= 0 {
            return err("server limits must be positive", "config")
        }
        return ok(true)
    }
}

/// Copyable stop handle. It is safe to pass to another thread; the accept
/// loop notices within `poll_timeout_ms`.
pub struct ServerControl {
    stopping: Atomic<bool>

    pub fn stop() -> Result<bool> {
        self.stopping.store(true, MemoryOrder.release)
        return ok(true)
    }

    pub fn is_stopping() -> bool {
        return self.stopping.load(MemoryOrder.acquire)
    }
}

/// Counts from one completed server run.
pub class ServerStats {
    pub accepted: int = 0
    pub rejected: int = 0
    pub requests: int = 0
    pub responses: int = 0
    pub connection_errors: int = 0
    pub active_peak: int = 0

    pub fn init() {}
}

// Live connection descriptors, for the graceful sweep only. Every touch
// happens on the owning worker thread — the accept fiber adds, each
// connection fiber removes itself before closing, the sweep iterates —
// and none of those operations parks, so they never interleave.
class ConnLedger {
    fds: List<int> = []
    at: Map<int, int> = {}

    fn init() {}

    fn add(fd: int) {
        self.at[fd] = self.fds.len()
        self.fds.push(fd)
    }

    fn remove(fd: int) {
        match self.at.get(fd) {
            some(index) => {
                let dropped: bool = self.at.remove(fd)
                let last: int = self.fds.len() - 1
                if index < last {
                    let moved: int = self.fds[last]
                    self.fds[index] = moved
                    self.at[moved] = index
                }
                let gone: Option<int> = self.fds.pop()
            }
            none => {}
        }
    }

    fn count() -> int { return self.fds.len() }

    // SHUT_RD (0) wakes parked reads into EOF so keep-alive connections
    // finish their in-flight response and leave; SHUT_RDWR (2) also fails
    // their writes, for the deadline that stops waiting politely.
    fn sweep(how: int) {
        for fd: int in self.fds {
            unsafe {
                let ignored: i32 = shutdown(fd, how)
            }
        }
    }
}

// Runs the pipeline on a child fiber so a panicking handler costs one
// request, not the connection fiber: the panic surfaces at the join as a
// plain error and becomes a 500. The brew sits in its own function because
// a scope join must ride a function body, never a loop iteration.
fn shielded_handle(app: WebApplication,
                   context: HttpContext) -> Result<bool> {
    let handled: Brew<Result<bool>> = brew app.handle_context(context)
    match handled.join() {
        ok(outcome) => { return outcome }
        err(problem) => { return err(problem.msg, problem.kind) }
    }
}

// One connection's whole life, owned by one fiber. Reads park in the
// netpoller, writes flush inline, and a deferred request waits right here
// in request order — the old pause/replay machinery is simply the fiber's
// program counter now.
unique class ServerConnection {
    stream: net.TcpStream
    peer: net.Address
    parser: http.RequestParser
    context: Option<HttpContext> = none
    have_head: bool = false
    events: List<http.RequestEvent> = []
    read_buffer: Bytes
    output: Bytes = new Bytes(0)
    close_after_write: bool = false
    requests: int = 0
    max_body: int
    // The head most recently adopted by the context. It goes back to the
    // parser for reuse only when the next head has replaced every alias to
    // it — the swap in absorb_event's head arm.
    previous_head: Option<http.Request> = none
    // The RFC 9110 Date value, cached per wall-clock second — see http_date().
    // This fiber is the sole toucher of a ServerConnection, so the cache needs
    // no lock and never crosses a thread.
    date_text: string = ""
    date_second: int = -1

    fn init(move stream: net.TcpStream,
            peer: net.Address,
            options: ServerOptions) {
        self.stream = move stream
        self.peer = peer
        let limits: http.Limits = new http.Limits()
        limits.max_header_count = options.max_header_count
        limits.max_header_bytes = options.max_header_bytes
        limits.max_target_bytes = options.max_target_bytes
        limits.max_head_span_bytes = options.max_head_span_bytes
        self.parser = http.RequestParser.with_limits(limits)
        self.read_buffer = new Bytes(options.read_buffer_bytes)
        self.output.reserve(1024)
        self.max_body = options.max_body_bytes
    }

    fn has_output() -> bool { return self.output.len() > 0 }

    // The RFC 9110 Date value for a response framed right now, as
    // IMF-fixdate in GMT — the only form a sender is allowed to generate.
    // Espresso is an origin server with a clock, so it MUST send Date on
    // 2xx/3xx/4xx and MAY on 1xx/5xx; it emits no 1xx, so "stamp it on every
    // response" is the simplest rule that is correct on every status it
    // produces, and append_response/append_error apply it at the one layer
    // that reaches a socket.
    //
    // Formatting is once-per-second work — a civil-time conversion and a few
    // string allocations — so the text is cached and reused for every
    // response that lands in the same wall-clock second. The wall clock is
    // read once per response (a vDSO clock_gettime, cheap beside the format it
    // guards), so the value is never stale: a response that crosses a second
    // boundary reformats before it is sent.
    fn http_date() -> string {
        let now_ns: int = time.wall_nanos()
        var second: int = now_ns / 1000000000
        // Floor toward the past, so a pre-epoch clock keeps a stable key.
        if now_ns < 0 && now_ns % 1000000000 != 0 { second -= 1 }
        if second != self.date_second {
            self.date_text =
                calendar.DateTime.from_epoch_nanos(now_ns).to_http_date()
            self.date_second = second
        }
        return self.date_text
    }

    // Frames a finished response, in whichever form it carries its payload.
    // Neither form copies the payload into a per-connection buffer: a small one
    // is appended to the output queue (which keeps pipelined responses batched),
    // a large one is sent beside its head with one vectored write.
    fn append_response_from(response: HttpResponse,
                            keep_alive: bool,
                            head_only: bool,
                            options: ServerOptions) -> Result<bool> {
        if response.is_text_body() {
            return self.append_response_text(
                response.status, response.reason, response.headers,
                response.text_payload(), keep_alive, head_only, options)
        }
        return self.append_response_bytes(
            response.status, response.reason, response.headers,
            response.body, keep_alive, head_only, options)
    }

    fn append_response_bytes(status: int,
                             reason: string,
                             headers: http.Headers,
                             body: Bytes,
                             keep_alive: bool,
                             head_only: bool,
                             options: ServerOptions) -> Result<bool> {
        if body.len() > options.max_response_body_bytes {
            return self.append_error(
                500, "Internal Server Error",
                "response body exceeds the configured limit", false, options)
        }
        // RFC 9110 §6.6.1: stamp Date unless the handler set its own (the
        // lookup is case-insensitive), so it is never emitted twice.
        if !headers.has("Date") {
            headers.add("Date", self.http_date())
        }
        let alive: bool = keep_alive && !self.close_after_write
        // A HEAD response is the head. Framing the whole response and then
        // cutting the body off the end copied every byte of it first — a
        // megabyte, on the static route — to reach a buffer it was about to
        // be removed from.
        if head_only {
            http.encode_response_head_append(
                self.output, status, reason, headers, body.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            return ok(true)
        }
        // Past this size, copying the body into the output queue costs more
        // than the extra write that avoids it: a 16 KB copy is around half a
        // microsecond and a send is one or two, and the gap only widens with
        // the body. Below it, appending keeps pipelined responses batched
        // into a single write, which is worth more than the copy costs.
        if body.len() >= vectored_body_min {
            let forbidden: bool = http.encode_response_head_append(
                self.output, status, reason, headers, body.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            if forbidden { return ok(true) }
            return self.flush_with_body(body)
        }
        http.encode_response_append(
            self.output, status, reason, headers, body, alive)?
        if !keep_alive { self.close_after_write = true }
        return ok(true)
    }

    // The string-body twin of append_response_bytes. The payload is the
    // handler's own string, framed from its length; it is never staged in a
    // response buffer. Below the threshold its bytes are appended straight to
    // the output queue, above it it is sent beside the head (flush_with_text).
    fn append_response_text(status: int,
                            reason: string,
                            headers: http.Headers,
                            text: string,
                            keep_alive: bool,
                            head_only: bool,
                            options: ServerOptions) -> Result<bool> {
        if text.len() > options.max_response_body_bytes {
            return self.append_error(
                500, "Internal Server Error",
                "response body exceeds the configured limit", false, options)
        }
        if !headers.has("Date") {
            headers.add("Date", self.http_date())
        }
        let alive: bool = keep_alive && !self.close_after_write
        if head_only {
            http.encode_response_head_append(
                self.output, status, reason, headers, text.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            return ok(true)
        }
        if text.len() >= vectored_body_min {
            let forbidden: bool = http.encode_response_head_append(
                self.output, status, reason, headers, text.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            if forbidden { return ok(true) }
            return self.flush_with_text(text)
        }
        // Small: frame the head, then append the string's bytes into the output
        // queue — the same wire bytes and the same single copy a Bytes body
        // takes through encode_response_append, but read from the handler's
        // string so nothing is staged in a response buffer first.
        let forbidden: bool = http.encode_response_head_append(
            self.output, status, reason, headers, text.len(), alive)?
        if !forbidden { self.output.append_string(text) }
        if !keep_alive { self.close_after_write = true }
        return ok(true)
    }

    // Sends the queued output and this response's body as one pair, without
    // the body ever entering the queue.
    //
    // Anything already queued is in front of the head this call just framed,
    // so writing the queue and the body together keeps pipelined responses in
    // order by construction: the body cannot overtake what was queued before
    // it, and nothing can be framed behind it until this returns.
    fn flush_with_body(body: Bytes) -> Result<bool> {
        var offset: int = 0
        let total: int = self.output.len() + body.len()
        for offset < total {
            match self.stream.write_vectored(self.output, body, offset) {
                ok(count) => {
                    if count <= 0 {
                        return err("the connection accepted no output",
                                   "reset")
                    }
                    offset += count
                }
                err(problem) => { return err(problem.msg, problem.kind) }
            }
        }
        self.output.resize(0)
        return ok(true)
    }

    // The string twin of flush_with_body. Until TcpStream.write_vectored_text
    // exists, the string is copied once into a fresh local buffer and sent
    // beside the head exactly as a Bytes body is; the buffer is a local and is
    // dropped when this returns, so — unlike the response buffer this work
    // removed — nothing keeps it between requests. The day write_vectored_text
    // lands, this body becomes a direct vectored send of the string with no
    // copy, and that swap is the only change.
    fn flush_with_text(text: string) -> Result<bool> {
        let payload: Bytes = new Bytes(0)
        payload.reserve(text.len())
        payload.append_string(text)
        return self.flush_with_body(payload)
    }

    fn append_error(status: int,
                    reason: string,
                    detail: string,
                    keep_alive: bool,
                    options: ServerOptions) -> Result<bool> {
        let headers: http.Headers = new http.Headers()
        headers.add("Content-Type", "text/plain; charset=utf-8")
        // RFC 9110 §6.6.1: an error response is 4xx or 5xx; a 4xx is a MUST.
        headers.add("Date", self.http_date())
        let body: Bytes = Bytes.from(detail)
        http.encode_response_append(
            self.output, status, reason, headers, body, keep_alive)?
        if !keep_alive { self.close_after_write = true }
        return ok(true)
    }

    // Waits for the Responder of a deferred request. The wait sits exactly
    // where the response must land, so pipelined requests behind it keep
    // their order by construction. A timeout answers 503 and closes; the
    // late payload, if it ever comes, sinks into the orphaned channel.
    fn await_completion(active: HttpContext,
                        app: WebApplication,
                        options: ServerOptions,
                        stats: ServerStats) -> Result<bool> {
        let keep_alive: bool = active.request.keep_alive
        let head_only: bool = active.head_only
        match active.take_reply() {
            some(reply) => {
                let deadline: int = time.monotonic_nanos() +
                    options.pending_timeout_ms * 1000000
                for {
                    match reply.try_receive() {
                        some(done) => {
                            let headers: http.Headers = new http.Headers()
                            for index: int in 0..done.header_names.len() {
                                headers.add(done.header_names[index],
                                            done.header_values[index])
                            }
                            if done.content_type != "" &&
                               !headers.has("Content-Type") {
                                headers.add("Content-Type", done.content_type)
                            }
                            if app.server_header() != "" &&
                               !headers.has("Server") {
                                headers.add("Server", app.server_header())
                            }
                            self.append_response_bytes(
                                done.status, done.reason, headers, done.body,
                                keep_alive, head_only, options)?
                            stats.responses += 1
                            return ok(true)
                        }
                        none => {}
                    }
                    if time.monotonic_nanos() >= deadline {
                        self.append_error(
                            503, "Service Unavailable",
                            "the deferred response timed out", false, options)?
                        stats.responses += 1
                        return ok(true)
                    }
                    time.sleep_millis(1)
                }
            }
            none => {
                return err("a deferred request lost its reply channel",
                           "state")
            }
        }
    }

    fn dispatch(app: WebApplication,
                keep_alive: bool,
                options: ServerOptions,
                stats: ServerStats) -> Result<bool> {
        self.requests += 1
        stats.requests += 1
        match self.context {
            some(active) => {
                active.request.keep_alive = keep_alive
                if self.requests >= options.max_requests_per_connection {
                    active.request.keep_alive = false
                }
                match shielded_handle(app, active) {
                    ok(_) => {
                        if active.deferred {
                            let closed: Result<bool> = active.close()
                            closed?
                            self.await_completion(
                                active, app, options, stats)?
                        } else {
                            let queued: Result<bool> =
                                self.append_response_from(
                                    active.response,
                                    active.request.keep_alive,
                                    active.head_only,
                                    options)
                            let closed: Result<bool> = active.close()
                            queued?
                            closed?
                            stats.responses += 1
                        }
                    }
                    err(problem) => {
                        // Every failure that reaches the shield's join — a
                        // contained panic, or an error handle_context could
                        // not render itself — is a server-side event worth a
                        // record, deferred or not. Log it once here, with the
                        // trace id the client will see, before the response is
                        // decided. This is the record the generic production
                        // message promises; without it a panic vanished
                        // silently (RequestLog runs inside the pipeline, which
                        // a panic unwinds straight past).
                        app.record_failure(active, problem.msg)
                        if active.deferred {
                            // A responder is already loose in the world; the
                            // request must wait for it no matter how the
                            // pipeline itself ended. The panic detail never
                            // reaches the client here — the responder's answer
                            // or a generic 503 does — so there is nothing to
                            // gate beyond the record above.
                            let closed: Result<bool> = active.close()
                            closed?
                            self.await_completion(
                                active, app, options, stats)?
                        } else {
                            // Connection policy: a handler error — a returned
                            // `err`, or a contained panic surfacing at the
                            // shield's join — is fatal to the connection.
                            // append_response is told keep_alive=false, so this
                            // response is the connection's last and it closes
                            // afterwards. That is deliberate: it bounds
                            // anything a half-finished request left on the
                            // reused HttpContext — and anything a panic would
                            // strand on a platform without the runtime unwind
                            // (Windows; see README) — to this one connection
                            // instead of letting the next request inherit it.
                            //
                            // Reclaim the request's DI scope first, best-effort
                            // on purpose: close() is idempotent and only errors
                            // when the scope was already released (so nothing
                            // leaks), and the error response below must still
                            // be framed — a close failure must not short-
                            // circuit past it. Surface a failure in the stats
                            // rather than swallow it.
                            match active.close() {
                                ok(_) => {}
                                err(_) => { stats.connection_errors += 1 }
                            }
                            // A contained panic leaves the response half-
                            // written at best, so start from a clean slate and
                            // render through the SAME gate and problem+json
                            // shape the returned-err path uses (write_failure):
                            // production answers the generic detail plus the
                            // trace id, detailed_errors answers the panic text.
                            // Never the bare panic message and never the
                            // "runtime panic at L:C" position the old
                            // append_error wrote straight to the wire.
                            active.response.reset()
                            app.write_failure(
                                active, problem.msg, problem.kind)?
                            if app.server_header() != "" &&
                               !active.response.headers.has("Server") {
                                active.response.header(
                                    "Server", app.server_header())
                            }
                            self.append_response_from(
                                active.response, false,
                                active.head_only, options)?
                            stats.responses += 1
                        }
                    }
                }
            }
            none => {
                return err("request completed without a context", "state")
            }
        }
        return ok(true)
    }

    // One parsed request event. `ok(false)` means stop absorbing: the
    // connection is closing.
    fn absorb_event(event: http.RequestEvent,
                    app: WebApplication,
                    options: ServerOptions,
                    stats: ServerStats) -> Result<bool> {
        match event {
            head(request) => {
                if self.context.is_none() {
                    let created: HttpContext = app.new_context(self.peer)
                    created.arm_serving()
                    self.context = some(created)
                }
                self.have_head = true
                match self.context {
                    some(active) => {
                        match app.begin_request(active, request) {
                            ok(_) => {
                                // begin_request replaced the context's view
                                // of the previous head, so its shell can go
                                // back to the parser for the next message.
                                match self.previous_head {
                                    some(done) => {
                                        self.parser.recycle(done)
                                    }
                                    none => {}
                                }
                                self.previous_head = some(request)
                            }
                            err(problem) => {
                                self.append_error(
                                    400, "Bad Request", problem.msg,
                                    false, options)?
                                self.close_after_write = true
                                return ok(false)
                            }
                        }
                    }
                    none => {}
                }
            }
            body(piece) => {
                match self.context {
                    some(active) => {
                        let grown: int =
                            active.request.body.len() + piece.len()
                        if grown > self.max_body {
                            self.append_error(
                                413, "Content Too Large",
                                "request body exceeds the configured limit",
                                false, options)?
                            self.close_after_write = true
                            return ok(false)
                        }
                        active.request.body.append(piece)
                    }
                    none => {}
                }
            }
            trailers(fields) => {
                match self.context {
                    some(active) => {
                        active.request.trailer_fields = fields
                    }
                    none => {}
                }
            }
            done(keep_alive) => {
                self.have_head = false
                self.dispatch(app, keep_alive, options, stats)?
            }
            upgraded(request, remainder) => {
                self.append_error(
                    400, "Bad Request",
                    "protocol upgrades are not enabled", false, options)?
                self.close_after_write = true
                return ok(false)
            }
        }
        return ok(true)
    }

    fn absorb(app: WebApplication,
              options: ServerOptions,
              stats: ServerStats) -> Result<bool> {
        for position: int in 0..self.events.len() {
            let proceed: bool = self.absorb_event(
                self.events[position], app, options, stats)?
            if !proceed { return ok(false) }
            if self.close_after_write { return ok(false) }
        }
        return ok(true)
    }

    // Pushes the whole output queue to the peer, parking on backpressure.
    fn flush() -> Result<bool> {
        var offset: int = 0
        for offset < self.output.len() {
            match self.stream.write_from(self.output, offset) {
                ok(count) => {
                    if count <= 0 {
                        return err("the connection accepted no output",
                                   "reset")
                    }
                    offset += count
                }
                err(problem) => { return err(problem.msg, problem.kind) }
            }
        }
        self.output.resize(0)
        return ok(true)
    }

    // The connection's whole life: read, parse, dispatch, flush, repeat.
    // Returns false when the connection died of a transport error the
    // stats should count, true for every clean ending.
    fn serve(app: WebApplication,
             options: ServerOptions,
             stats: ServerStats) -> bool {
        let armed: Result<bool> = self.stream.set_timeouts(
            options.idle_timeout_ms, options.idle_timeout_ms)
        for !self.close_after_write {
            // wait-first: between requests the socket is drained, so the
            // speculative recv would only say would-block.
            match self.stream.read_into_waiting(self.read_buffer) {
                ok(count) => {
                    if count == 0 {
                        self.close_after_write = true
                        self.events.clear()
                        match self.parser.finish_into(self.events) {
                            ok(_) => {
                                match self.absorb(app, options, stats) {
                                    ok(_) => {}
                                    err(problem) => { return false }
                                }
                            }
                            err(problem) => {
                                if self.have_head {
                                    match self.append_error(
                                            400, "Bad Request", problem.msg,
                                            false, options) {
                                        ok(_) => {}
                                        err(broken) => { return false }
                                    }
                                }
                            }
                        }
                        break
                    }
                    self.events.clear()
                    match self.parser.feed_range_into(
                            self.read_buffer, 0, count, self.events) {
                        ok(_) => {
                            match self.absorb(app, options, stats) {
                                ok(_) => {}
                                err(problem) => { return false }
                            }
                        }
                        err(problem) => {
                            let refused: Result<bool> = self.append_error(
                                if problem.kind == "too_large" { 431 }
                                else { 400 },
                                if problem.kind == "too_large" {
                                    "Request Header Fields Too Large"
                                } else { "Bad Request" },
                                problem.msg, false, options)
                            match refused {
                                ok(_) => {}
                                err(broken) => { return false }
                            }
                            self.close_after_write = true
                        }
                    }
                    if self.has_output() {
                        match self.flush() {
                            ok(_) => {}
                            err(problem) => { return false }
                        }
                    }
                }
                err(problem) => {
                    // An idle keep-alive connection timing out, or the peer
                    // vanishing between requests, is a quiet ending; a
                    // failure mid-request counts.
                    if problem.kind == "timeout" { return true }
                    return !self.have_head
                }
            }
        }
        if self.has_output() {
            match self.flush() {
                ok(_) => {}
                err(problem) => { return false }
            }
        }
        return true
    }

    fn close() -> Result<bool> { return self.stream.close() }
}


// One connection fiber. It owns the stream outright; the ledger entry
// exists only so the graceful sweep can reach the descriptor from outside.
// If this function ever panicked, the abandoned frames would leak the
// socket and strand its ledger entry — which is why the panic boundary
// sits deeper, around the handler, and everything here speaks in Results.
fn connection_main(move stream: net.TcpStream,
                   app: WebApplication,
                   options: ServerOptions,
                   stats: ServerStats,
                   ledger: ConnLedger) -> int {
    let fd: int = stream.poll_handle()
    let ignored_nodelay: Result<bool> = stream.set_nodelay(true)
    var peer: net.Address = new net.Address("", 0)
    var ready: bool = true
    match stream.peer_address() {
        ok(address) => { peer = address }
        err(problem) => { ready = false }
    }
    if !ready {
        stats.connection_errors += 1
        ledger.remove(fd)
        let ignored: Result<bool> = stream.close()
        return 0
    }
    let connection: ServerConnection =
        new ServerConnection(move stream, peer, options)
    let stood: bool = connection.serve(app, options, stats)
    if !stood { stats.connection_errors += 1 }
    // Unregister before closing: the sweep must never see a descriptor
    // the kernel may already have reissued.
    ledger.remove(fd)
    let ignored_close: Result<bool> = connection.close()
    return 0
}

/// One HTTP/1.1 worker: an accept loop that gives every connection its own
/// fiber. Connections park in the worker's netpoller between requests, so
/// the loop itself only accepts, reaps, and answers the stop signal.
pub unique class WebServer {
    app: WebApplication
    options: ServerOptions
    listener: Option<net.TcpListener> = none
    feed: Option<Channel<net.TcpStream>> = none
    stopping: Atomic<bool> = new Atomic<bool>(false)
    resources_live: bool = true

    fn init(app: WebApplication, options: ServerOptions) {
        self.app = app
        self.options = options
    }

    pub static fn bind(app: WebApplication,
                       options: ServerOptions) -> Result<WebServer> {
        options.validate()?
        let listener: net.TcpListener = net.TcpListener.bind_with_backlog(
            options.host, options.port, options.backlog)?
        return WebServer.adopt(app, options, move listener)
    }

    /// Wraps an already-bound listener.
    pub static fn adopt(app: WebApplication,
                        options: ServerOptions,
                        move listener: net.TcpListener) -> Result<WebServer> {
        options.validate()?
        let server: WebServer = new WebServer(app, options)
        server.listener = some(move listener)
        return ok(move server)
    }

    // A worker inside `serve`: connections arrive from the acceptor
    // through the channel; closing the channel is the stop signal.
    static fn fed(app: WebApplication,
                  options: ServerOptions,
                  feed: Channel<net.TcpStream>) -> Result<WebServer> {
        options.validate()?
        let server: WebServer = new WebServer(app, options)
        server.feed = some(feed)
        return ok(move server)
    }

    pub fn port() -> Result<int> {
        match self.listener {
            some(bound) => { return bound.port() }
            none => { return err("this worker owns no listener", "state") }
        }
    }

    pub fn control() -> ServerControl {
        return ServerControl {
            stopping: self.stopping,
        }
    }

    /// Serves until `control().stop()` asks for shutdown (or, for a fed
    /// worker, until the acceptor closes the feed), then drains: reads are
    /// shut so keep-alive connections finish and leave, and connections
    /// still working past the graceful deadline lose their writes too.
    pub fn run() -> Result<ServerStats> {
        if !self.resources_live {
            return err("the server is closed", "closed")
        }
        let stats: ServerStats = new ServerStats()
        let ledger: ConnLedger = new ConnLedger()
        let group: TaskGroup<int> = new TaskGroup<int>()
        var active: int = 0
        var failed: Option<Error> = none
        let fed: bool = self.listener.is_none()

        for {
            if !fed && self.stopping.load(MemoryOrder.acquire) { break }

            // Claim every finished connection fiber. A row that ends in
            // error is an engine fault on that connection — counted, never
            // fatal to the worker.
            for {
                match group.try_next() {
                    some(outcome) => {
                        active -= 1
                        match outcome {
                            ok(_) => {}
                            err(problem) => {
                                stats.connection_errors += 1
                            }
                        }
                    }
                    none => { break }
                }
            }

            var landed: Option<net.TcpStream> = none
            var closing: bool = false
            match self.listener {
                some(bound) => {
                    let arrived: Result<net.TcpStream> =
                        bound.accept_timeout(self.options.poll_timeout_ms)
                    var quiet: bool = false
                    match arrived {
                        ok(_) => {}
                        err(problem) => {
                            quiet = true
                            if problem.kind != "timeout" {
                                failed = some(problem)
                                closing = true
                            }
                        }
                    }
                    if !quiet {
                        landed = some((move arrived).expect("accepted stream"))
                    }
                }
                none => {}
            }
            match self.feed {
                some(source) => {
                    var handed: Option<net.TcpStream> = source.receive()
                    if handed.is_none() {
                        closing = true
                    } else {
                        landed = move handed
                    }
                }
                none => {}
            }

            if !landed.is_none() {
                let stream: net.TcpStream =
                    (move landed).expect("connection stream")
                if active >= self.options.max_connections {
                    stats.rejected += 1
                    let ignored: Result<bool> = stream.close()
                } else {
                    ledger.add(stream.poll_handle())
                    stats.accepted += 1
                    active += 1
                    if active > stats.active_peak {
                        stats.active_peak = active
                    }
                    group.brew(connection_main(
                        move stream, self.app, self.options, stats, ledger))
                }
            }
            if closing { break }
        }

        self.stop_accepting()
        // Graceful drain: wake every parked read into EOF, give in-flight
        // work the configured grace, then stop being polite.
        ledger.sweep(0)
        let deadline: int = time.monotonic_nanos() +
            self.options.graceful_shutdown_ms * 1000000
        var forced: bool = false
        for {
            for {
                match group.try_next() {
                    some(outcome) => {
                        active -= 1
                        match outcome {
                            ok(_) => {}
                            err(problem) => {
                                stats.connection_errors += 1
                            }
                        }
                    }
                    none => { break }
                }
            }
            if active <= 0 { break }
            if !forced && time.monotonic_nanos() >= deadline {
                ledger.sweep(2)
                forced = true
            }
            time.sleep_millis(10)
        }
        self.close_resources()
        match failed {
            some(problem) => { return err(problem.msg, problem.kind) }
            none => {}
        }
        return ok(stats)
    }

    fn stop_accepting() {
        match self.listener {
            some(bound) => {
                let ignored: Result<bool> = bound.close()
            }
            none => {}
        }
        self.listener = none
    }

    fn close_resources() {
        if !self.resources_live { return }
        self.stop_accepting()
        let ignored_app: Result<bool> = self.app.close()
        self.resources_live = false
    }

    pub fn close() -> Result<bool> {
        if !self.resources_live { return err("the server is closed", "closed") }
        self.stopping.store(true, MemoryOrder.release)
        self.close_resources()
        return ok(true)
    }

    fn deinit() { self.close_resources() }
}
