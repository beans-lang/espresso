package espresso

import std.async as aio
import std.http
import std.net
import std.time

/// Bounds for the listener, parser, connections, bodies, and output queues.
pub class ServerOptions {
    pub host: string = "127.0.0.1"
    pub port: int = 8080
    pub backlog: int = 512
    pub max_connections: int = 10000
    pub idle_timeout_ms: int = 30000
    pub graceful_shutdown_ms: int = 10000
    /// Maximum time spent inside one request pipeline.
    /// Zero uses the 30 second default or the deprecated compatibility field.
    pub request_timeout_ms: int = 0
    /// Deprecated in 0.3. Zero means unset. Use request_timeout_ms.
    pub pending_timeout_ms: int = 0
    pub read_buffer_bytes: int = 65536
    pub max_body_bytes: int = 8388608
    pub max_response_body_bytes: int = 16777216
    pub max_pending_output_bytes: int = 33554432
    /// Responses queue into the connection's output buffer and flush once
    /// per parsed read batch, so a pipelined burst costs one write. A
    /// burst that outgrows this watermark flushes early at the next
    /// request boundary instead of holding finished responses.
    pub flush_watermark_bytes: int = 65536
    /// macOS delays a busy thread's kevent wakeups while sibling threads
    /// sit in long waits. A pulse task bounds every driver wait to this
    /// interval, the same guard the 0.2 poll loop carried. Zero disables.
    pub wake_guard_ms: int = 25
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
           self.idle_timeout_ms <= 0 || self.graceful_shutdown_ms < 0 ||
           self.request_timeout_ms < 0 || self.pending_timeout_ms < 0 ||
           self.read_buffer_bytes <= 0 || self.max_body_bytes <= 0 ||
           self.max_response_body_bytes <= 0 ||
           self.max_pending_output_bytes <= 0 ||
           self.flush_watermark_bytes <= 0 || self.wake_guard_ms < 0 ||
           self.max_requests_per_connection <= 0 ||
           self.max_header_count <= 0 || self.max_header_bytes <= 0 ||
           self.max_target_bytes <= 0 || self.max_head_span_bytes <= 0 {
            return err("server limits must be positive", "config")
        }
        return ok(true)
    }

    fn effective_request_timeout_ms() -> int {
        if self.request_timeout_ms > 0 { return self.request_timeout_ms }
        if self.pending_timeout_ms > 0 { return self.pending_timeout_ms }
        return 30000
    }
}

/// Copyable stop handle. It wakes an async server from any thread.
pub struct ServerControl {
    stopping: Atomic<bool>
    shutdown: aio.Event

    pub fn stop() -> Result<bool> {
        self.stopping.store(true, MemoryOrder.release)
        self.shutdown.set()
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

enum IoWait {
    ready(live: bool)
    expired
}

async fn read_ready(handle: int) -> IoWait {
    return IoWait.ready(await net.readable(handle))
}

async fn write_ready(handle: int) -> IoWait {
    return IoWait.ready(await net.writable(handle))
}

async fn io_deadline(deadline_nanos: int) -> IoWait {
    await aio.sleep_until(deadline_nanos)
    return IoWait.expired
}

async fn wait_for_read(handle: int, deadline_nanos: int) -> bool {
    let waits: aio.TaskGroup<IoWait> = new aio.TaskGroup<IoWait>()
    waits.start(read_ready(handle))
    waits.start(io_deadline(deadline_nanos))
    let first: Option<IoWait> = await waits.next()
    waits.cancel_all()
    match first.expect("read wait") {
        ready(live) => { return live }
        expired => { return false }
    }
}

async fn wait_for_write(handle: int, deadline_nanos: int) -> bool {
    let waits: aio.TaskGroup<IoWait> = new aio.TaskGroup<IoWait>()
    waits.start(write_ready(handle))
    waits.start(io_deadline(deadline_nanos))
    let first: Option<IoWait> = await waits.next()
    waits.cancel_all()
    match first.expect("write wait") {
        ready(live) => { return live }
        expired => { return false }
    }
}

enum RequestWait {
    completed(result: Result<bool>)
    expired
}

async fn execute_request(app: WebApplication,
                         context: HttpContext) -> RequestWait {
    return RequestWait.completed(await app.handle_context(context))
}

async fn request_deadline(deadline_nanos: int) -> RequestWait {
    await aio.sleep_until(deadline_nanos)
    return RequestWait.expired
}

struct ConnectionReport {
    failed: bool
}

unique class ServerConnection {
    stream: net.TcpStream
    peer: net.Address
    parser: http.RequestParser
    context: Option<HttpContext> = none
    have_head: bool = false
    events: List<http.RequestEvent> = []
    read_buffer: Bytes
    output: Bytes = new Bytes(0)
    output_offset: int = 0
    close_after_write: bool = false
    requests: int = 0
    last_active_nanos: int
    max_body: int
    live: bool = true
    previous_head: Option<http.Request> = none

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
        self.last_active_nanos = time.monotonic_nanos()
        self.max_body = options.max_body_bytes
    }

    fn compact_output() {
        if self.output_offset <= 0 { return }
        if self.output_offset >= self.output.len() {
            self.output.resize(0)
        } else {
            let remaining: Bytes = self.output.slice(
                self.output_offset, self.output.len())
            self.output = move remaining
        }
        self.output_offset = 0
    }

    fn append_response(status: int,
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
        self.compact_output()
        let start: int = self.output.len()
        http.encode_response_append(
            self.output, status, reason, headers, body,
            keep_alive && !self.close_after_write)?
        if head_only && body.len() <= self.output.len() - start {
            self.output.resize(self.output.len() - body.len())
        }
        if self.output.len() > options.max_pending_output_bytes {
            self.output.resize(start)
            self.close_after_write = true
            if start == 0 {
                return self.append_error(
                    503, "Service Unavailable",
                    "connection output queue is full", false, options)
            }
            return ok(false)
        }
        if !keep_alive { self.close_after_write = true }
        return ok(true)
    }

    fn append_error(status: int,
                    reason: string,
                    detail: string,
                    keep_alive: bool,
                    options: ServerOptions) -> Result<bool> {
        let headers: http.Headers = new http.Headers()
        headers.add("Content-Type", "text/plain; charset=utf-8")
        let body: Bytes = Bytes.from(detail)
        self.compact_output()
        let start: int = self.output.len()
        http.encode_response_append(
            self.output, status, reason, headers, body, keep_alive)?
        if self.output.len() > options.max_pending_output_bytes {
            self.output.resize(start)
        }
        if !keep_alive { self.close_after_write = true }
        return ok(true)
    }

    async fn flush(options: ServerOptions) -> Result<bool> {
        for self.output_offset < self.output.len() {
            match self.stream.try_write_from(
                    self.output, self.output_offset)? {
                none => {
                    let deadline: int = self.last_active_nanos +
                        options.idle_timeout_ms * 1000000
                    if !await wait_for_write(
                            self.stream.poll_handle(), deadline) {
                        return err(
                            "the connection write timed out", "timeout")
                    }
                }
                some(count) => {
                    if count <= 0 {
                        return err(
                            "the connection accepted no output", "reset")
                    }
                    self.output_offset += count
                    self.last_active_nanos = time.monotonic_nanos()
                }
            }
        }
        self.compact_output()
        return ok(true)
    }

    async fn dispatch(app: WebApplication,
                      keep_alive: bool,
                      options: ServerOptions,
                      stats: ServerStats) -> Result<bool> {
        self.requests += 1
        stats.requests += 1
        match self.context {
            none => {
                return err("request completed without a context", "state")
            }
            some(active) => {
                active.request.keep_alive = keep_alive
                if self.requests >= options.max_requests_per_connection {
                    active.request.keep_alive = false
                }

                if self.output.len() >= options.flush_watermark_bytes {
                    await self.flush(options)?
                }
                let work: aio.TaskGroup<RequestWait> =
                    new aio.TaskGroup<RequestWait>()
                work.start(execute_request(app, active))
                var first: RequestWait = RequestWait.expired
                match work.try_next() {
                    some(done) => { first = done }
                    none => {
                        work.start(request_deadline(
                            time.monotonic_nanos() +
                            options.effective_request_timeout_ms() *
                                1000000))
                        first = (await work.next())
                            .expect("request wait")
                    }
                }
                work.cancel_all()

                var queued: Result<bool> = ok(true)
                match first {
                    completed(result) => {
                        match result {
                            ok(_) => {
                                queued = self.append_response(
                                    active.response.status,
                                    active.response.reason,
                                    active.response.headers,
                                    active.response.body,
                                    active.request.keep_alive,
                                    active.head_only,
                                    options)
                            }
                            err(problem) => {
                                let status: int =
                                    if problem.kind == "bad_request" {
                                        400
                                    } else { 500 }
                                queued = self.append_error(
                                    status,
                                    if status == 400 {
                                        "Bad Request"
                                    } else { "Internal Server Error" },
                                    problem.msg, false, options)
                            }
                        }
                    }
                    expired => {
                        queued = self.append_error(
                            503, "Service Unavailable",
                            "the request timed out", false, options)
                    }
                }
                let closed: Result<bool> = active.close()
                queued?
                closed?
                stats.responses += 1
                return ok(!self.close_after_write)
            }
        }
    }

    async fn absorb_event(event: http.RequestEvent,
                          app: WebApplication,
                          options: ServerOptions,
                          stats: ServerStats) -> Result<bool> {
        match event {
            head(request) => {
                if self.context.is_none() {
                    self.context = some(app.new_context(self.peer))
                }
                self.have_head = true
                match self.context {
                    some(active) => {
                        match app.begin_request(active, request) {
                            ok(_) => {
                                match self.previous_head {
                                    some(done) => { self.parser.recycle(done) }
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
                        let grown: int = active.request.body.len() + piece.len()
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
                return await self.dispatch(app, keep_alive, options, stats)
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

    async fn absorb(app: WebApplication,
                    options: ServerOptions,
                    stats: ServerStats) -> Result<bool> {
        for position: int in 0..self.events.len() {
            if !await self.absorb_event(
                    self.events[position], app, options, stats)? {
                return ok(false)
            }
        }
        return ok(true)
    }

    async fn run(app: WebApplication,
                 options: ServerOptions,
                 stats: ServerStats) -> Result<bool> {
        var wait_before_read: bool = false
        for !self.close_after_write {
            if wait_before_read {
                let deadline: int = self.last_active_nanos +
                    options.idle_timeout_ms * 1000000
                if !await wait_for_read(
                        self.stream.poll_handle(), deadline) {
                    return ok(true)
                }
                wait_before_read = false
            }
            match self.stream.try_read_into(self.read_buffer)? {
                none => {
                    let deadline: int = self.last_active_nanos +
                        options.idle_timeout_ms * 1000000
                    if !await wait_for_read(
                            self.stream.poll_handle(), deadline) {
                        return ok(true)
                    }
                }
                some(count) => {
                    self.last_active_nanos = time.monotonic_nanos()
                    self.events.clear()
                    if count == 0 {
                        match self.parser.finish_into(self.events) {
                            ok(_) => {
                                await self.absorb(app, options, stats)?
                                if self.output.len() > 0 {
                                    await self.flush(options)?
                                }
                            }
                            err(problem) => {
                                if self.have_head {
                                    self.append_error(
                                        400, "Bad Request", problem.msg,
                                        false, options)?
                                    await self.flush(options)?
                                }
                            }
                        }
                        return ok(true)
                    }
                    match self.parser.feed_range_into(
                            self.read_buffer, 0, count, self.events) {
                        ok(_) => {
                            if !await self.absorb(app, options, stats)? {
                                if self.output.len() > 0 {
                                    await self.flush(options)?
                                }
                                return ok(true)
                            }
                            if self.output.len() > 0 {
                                await self.flush(options)?
                            }
                        }
                        err(problem) => {
                            self.append_error(
                                if problem.kind == "too_large" { 431 } else { 400 },
                                if problem.kind == "too_large" {
                                    "Request Header Fields Too Large"
                                } else { "Bad Request" },
                                problem.msg, false, options)?
                            await self.flush(options)?
                            return ok(true)
                        }
                    }
                    if count < self.read_buffer.len() {
                        wait_before_read = true
                    }
                }
            }
        }
        return ok(true)
    }

    fn close() -> Result<bool> {
        if !self.live { return ok(true) }
        self.live = false
        return self.stream.close()
    }
}

enum ServerEvent {
    listener(live: bool)
    stopping
    shutdown_deadline
    pulse
    intake_wake
    intake_closed
    connection(report: ConnectionReport)
}

async fn listener_ready(handle: int) -> ServerEvent {
    return ServerEvent.listener(await net.readable(handle))
}

async fn shutdown_requested(event: aio.Event) -> ServerEvent {
    await event.wait()
    return ServerEvent.stopping
}

async fn wake_pulse(interval_ms: int) -> ServerEvent {
    await aio.sleep_millis(interval_ms)
    return ServerEvent.pulse
}

async fn intake_pulse(wake: Channel<bool>) -> ServerEvent {
    let woke: Option<bool> = await wake.receive_async()
    if woke.is_none() { return ServerEvent.intake_closed }
    return ServerEvent.intake_wake
}

async fn shutdown_limit(deadline_nanos: int) -> ServerEvent {
    await aio.sleep_until(deadline_nanos)
    return ServerEvent.shutdown_deadline
}

async fn serve_connection(move stream: net.TcpStream,
                          peer: net.Address,
                          app: WebApplication,
                          options: ServerOptions,
                          stats: ServerStats) -> ServerEvent {
    let connection: ServerConnection =
        new ServerConnection(move stream, peer, options)
    defer connection.close()
    match await connection.run(app, options, stats) {
        ok(_) => {
            return ServerEvent.connection(ConnectionReport {
                failed: false,
            })
        }
        err(_) => {
            return ServerEvent.connection(ConnectionReport {
                failed: true,
            })
        }
    }
}

/// Structured async HTTP/1.1 server. Every accepted connection is a child of
/// `run`; shutdown cancels no work until the grace deadline expires.
pub unique class WebServer {
    app: WebApplication
    options: ServerOptions
    listener: Option<net.TcpListener>
    intake: Option<Channel<net.TcpStream>> = none
    intake_wake: Option<Channel<bool>> = none
    stopping: Atomic<bool> = new Atomic<bool>(false)
    shutdown: aio.Event = new aio.Event()
    listener_live: bool = true
    resources_live: bool = true

    fn init(app: WebApplication,
            options: ServerOptions,
            move listener: Option<net.TcpListener>) {
        self.app = app
        self.options = options
        self.listener = move listener
    }

    pub static fn bind(app: WebApplication,
                       options: ServerOptions) -> Result<WebServer> {
        options.validate()?
        let listener: net.TcpListener = net.TcpListener.bind_with_backlog(
            options.host, options.port, options.backlog)?
        return WebServer.adopt(app, options, move listener)
    }

    pub static fn adopt(app: WebApplication,
                        options: ServerOptions,
                        move listener: net.TcpListener) -> Result<WebServer> {
        options.validate()?
        listener.set_nonblocking(true)?
        return ok(new WebServer(app, options, some(move listener)))
    }

    /// A worker fed by an acceptor thread: connections arrive owned on
    /// `streams`, and `wake` carries best-effort nudges — one drain per
    /// nudge, one nudge per completion while streams wait. The acceptor
    /// owns both channels and closes them to stop the worker accepting.
    pub static fn adopt_intake(app: WebApplication,
                               options: ServerOptions,
                               streams: Channel<net.TcpStream>,
                               wake: Channel<bool>) -> Result<WebServer> {
        options.validate()?
        let server: WebServer = new WebServer(app, options, none)
        server.intake = some(streams)
        server.intake_wake = some(wake)
        return ok(move server)
    }

    pub fn port() -> Result<int> {
        match self.listener {
            some(bound) => { return bound.port() }
            none => {
                return err(
                    "an intake worker has no listener of its own",
                    "intake")
            }
        }
    }

    pub fn control() -> ServerControl {
        return ServerControl {
            stopping: self.stopping,
            shutdown: self.shutdown,
        }
    }

    fn intake_source() -> Channel<net.TcpStream> {
        return self.intake.expect("intake source")
    }

    fn intake_nudges() -> Channel<bool> {
        return self.intake_wake.expect("intake nudges")
    }

    fn listener_handle() -> int {
        match self.listener {
            some(bound) => { return bound.poll_handle() }
            none => { return 0 - 1 }
        }
    }

    fn stop_accepting() {
        if !self.listener_live { return }
        match self.listener {
            some(bound) => {
                let ignored: Result<bool> = bound.close()
            }
            none => {}
        }
        self.listener_live = false
    }

    fn close_resources() {
        if !self.resources_live { return }
        self.stop_accepting()
        let ignored: Result<bool> = self.app.close()
        self.resources_live = false
    }

    /// Runs until `control().stop()` is called.
    pub async fn run() -> Result<ServerStats> {
        if !self.resources_live {
            return err("the server is closed", "closed")
        }
        defer self.close_resources()
        let stats: ServerStats = new ServerStats()
        let children: aio.TaskGroup<ServerEvent> =
            new aio.TaskGroup<ServerEvent>()
        children.start(shutdown_requested(self.shutdown))
        let watched: int = self.listener_handle()
        if watched >= 0 {
            children.start(listener_ready(watched))
        }
        if self.intake_wake.is_some() {
            children.start(intake_pulse(self.intake_nudges()))
        }
        if self.options.wake_guard_ms > 0 {
            children.start(wake_pulse(self.options.wake_guard_ms))
        }

        var active: int = 0
        var accepting: bool = true
        var listener_waiting: bool = true
        var failed_message: string = ""
        var failed_kind: string = ""
        var deadline_started: bool = false

        for accepting || active > 0 {
            let next: Option<ServerEvent> = await children.next()
            if next.is_none() {
                failed_message = "the server task group became empty"
                failed_kind = "state"
                break
            }
            match (move next).expect("server child") {
                listener(live) => {
                    listener_waiting = false
                    if !accepting { continue }
                    if !live {
                        failed_message = "the listening socket closed"
                        failed_kind = "closed"
                        accepting = false
                        self.stop_accepting()
                        children.cancel_all()
                        active = 0
                        break
                    }
                    var accept_failed: bool = false
                    var accepted_this_turn: int = 0
                    for accepted_this_turn < 64 &&
                        active < self.options.max_connections {
                        var accepted: Result<Option<net.TcpStream>> =
                            ok(none)
                        match self.listener {
                            some(bound) => {
                                accepted = bound.try_accept()
                            }
                            none => {}
                        }
                        var accept_transient: bool = false
                        match accepted {
                            err(problem) => {
                                // a handshake torn down while queued
                                // surfaces as a reset; only a closed
                                // listener ends accepting
                                if problem.kind == "closed" {
                                    failed_message = problem.msg
                                    failed_kind = problem.kind
                                    accept_failed = true
                                } else {
                                    accept_transient = true
                                }
                            }
                            ok(_) => {}
                        }
                        if accept_failed || accept_transient { break }
                        let pending: Option<net.TcpStream> =
                            (move accepted).expect("accept result")
                        if pending.is_none() { break }
                        let stream: net.TcpStream =
                            (move pending).expect("accepted stream")
                        accepted_this_turn += 1
                        var peer: Option<net.Address> = none
                        var ready: bool = true
                        match stream.set_nonblocking(true) {
                            ok(_) => {}
                            err(_) => { ready = false }
                        }
                        let ignored_nodelay: Result<bool> =
                            stream.set_nodelay(true)
                        if ready {
                            match stream.peer_address() {
                                ok(address) => { peer = some(address) }
                                err(_) => {}
                            }
                        }
                        if peer.is_none() {
                            stats.connection_errors += 1
                            let ignored: Result<bool> = stream.close()
                            continue
                        }
                        stats.accepted += 1
                        active += 1
                        if active > stats.active_peak {
                            stats.active_peak = active
                        }
                        children.start(serve_connection(
                            move stream,
                            (move peer).expect("peer address"),
                            self.app, self.options, stats))
                    }
                    if accept_failed {
                        accepting = false
                        self.stop_accepting()
                        children.cancel_all()
                        active = 0
                        break
                    } else if accepted_this_turn >= 64 {
                        await aio.yield_now()
                    }
                    if accepting &&
                       active < self.options.max_connections &&
                       !listener_waiting {
                        let rearmed: int = self.listener_handle()
                        if rearmed >= 0 {
                            children.start(listener_ready(rearmed))
                            listener_waiting = true
                        }
                    }
                }
                stopping => {
                    if accepting {
                        accepting = false
                        self.stop_accepting()
                    }
                    if active > 0 && !deadline_started {
                        deadline_started = true
                        children.start(shutdown_limit(
                            time.monotonic_nanos() +
                            self.options.graceful_shutdown_ms * 1000000))
                    }
                }
                shutdown_deadline => {
                    children.cancel_all()
                    active = 0
                    break
                }
                pulse => {
                    if self.options.wake_guard_ms > 0 &&
                       (accepting || active > 0) {
                        children.start(wake_pulse(
                            self.options.wake_guard_ms))
                    }
                }
                intake_wake => {
                    if accepting {
                        for active < self.options.max_connections {
                            var taken: Option<net.TcpStream> =
                                self.intake_source().try_receive()
                            if taken.is_none() { break }
                            let stream: net.TcpStream =
                                (move taken).expect("adopted stream")
                            var peer: Option<net.Address> = none
                            var ready: bool = true
                            match stream.set_nonblocking(true) {
                                ok(_) => {}
                                err(_) => { ready = false }
                            }
                            let ignored_nodelay: Result<bool> =
                                stream.set_nodelay(true)
                            if ready {
                                match stream.peer_address() {
                                    ok(address) => {
                                        peer = some(address)
                                    }
                                    err(_) => {}
                                }
                            }
                            if peer.is_none() {
                                stats.connection_errors += 1
                                let ignored: Result<bool> =
                                    stream.close()
                                continue
                            }
                            stats.accepted += 1
                            active += 1
                            if active > stats.active_peak {
                                stats.active_peak = active
                            }
                            children.start(serve_connection(
                                move stream,
                                (move peer).expect("peer address"),
                                self.app, self.options, stats))
                        }
                        if self.intake_wake.is_some() {
                            children.start(intake_pulse(
                                self.intake_nudges()))
                        }
                    }
                }
                intake_closed => {
                    accepting = false
                }
                connection(report) => {
                    active -= 1
                    if report.failed {
                        stats.connection_errors += 1
                    }
                    if accepting &&
                       active < self.options.max_connections &&
                       !listener_waiting {
                        let refreshed: int = self.listener_handle()
                        if refreshed >= 0 {
                            children.start(listener_ready(refreshed))
                            listener_waiting = true
                        }
                    }
                    if accepting && self.intake_wake.is_some() {
                        let nudged: bool =
                            self.intake_nudges().try_send(true)
                    }
                }
            }
        }

        children.cancel_all()
        if failed_message != "" {
            return err(failed_message, failed_kind)
        }
        return ok(stats)
    }
}
