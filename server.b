package espresso

import std.http
import std.net
import std.poll
import std.time

/// Bounds for the listener, parser, connections, bodies, and output queues.
pub class ServerOptions {
    pub host: string = "127.0.0.1"
    pub port: int = 8080
    pub backlog: int = 512
    pub max_connections: int = 10000
    pub max_events: int = 256
    pub poll_timeout_ms: int = 1000
    pub idle_timeout_ms: int = 30000
    pub graceful_shutdown_ms: int = 10000
    pub read_buffer_bytes: int = 65536
    pub max_body_bytes: int = 8388608
    pub max_response_body_bytes: int = 16777216
    pub max_pending_output_bytes: int = 33554432
    pub max_requests_per_connection: int = 1000
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

/// Copyable stop handle. It is safe to pass to another thread.
pub struct ServerControl {
    stopping: Atomic<bool>
    signal: int

    pub fn stop() -> Result<bool> {
        self.stopping.store(true, MemoryOrder.release)
        return poll.wake(self.signal)
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

unique class ServerConnection {
    stream: net.TcpStream
    peer: net.Address
    parser: http.RequestParser
    building: http.ServedRequest = new http.ServedRequest()
    have_head: bool = false
    read_buffer: Bytes
    output: Bytes = new Bytes(0)
    response_buffer: Bytes = new Bytes(0)
    output_offset: int = 0
    close_after_write: bool = false
    read_paused: bool = false
    requests: int = 0
    last_active_nanos: int
    max_body: int

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
        self.response_buffer.reserve(1024)
        self.last_active_nanos = time.monotonic_nanos()
        self.max_body = options.max_body_bytes
    }

    fn handle() -> int { return self.stream.poll_handle() }

    fn has_output() -> bool { return self.output_offset < self.output.len() }

    fn idle(now: int, timeout_ms: int) -> bool {
        return now - self.last_active_nanos > timeout_ms * 1000000
    }

    fn interest() -> poll.Interest {
        let read: bool = !self.close_after_write && !self.read_paused
        let write: bool = self.has_output()
        return new poll.Interest(read, write)
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
        http.encode_response_into(
            self.response_buffer, status, reason, headers, body,
            keep_alive && !self.close_after_write)?
        if head_only && body.len() <= self.response_buffer.len() {
            self.response_buffer.resize(
                self.response_buffer.len() - body.len())
        }
        self.compact_output()
        let pending_size: int =
            self.output.len() + self.response_buffer.len()
        if pending_size > options.max_pending_output_bytes {
            self.close_after_write = true
            self.read_paused = true
            if self.output.len() == 0 {
                return self.append_error(
                    503, "Service Unavailable",
                    "connection output queue is full", false, options)
            }
            return ok(false)
        }
        self.output.append(self.response_buffer)
        if !keep_alive { self.close_after_write = true }
        if self.output.len() >= options.max_pending_output_bytes / 2 {
            self.read_paused = true
        }
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
        // Error text is bounded by the framework, so this call cannot recurse
        // through the response-body limit.
        http.encode_response_into(
            self.response_buffer, status, reason, headers, body, keep_alive)?
        self.compact_output()
        let pending_size: int =
            self.output.len() + self.response_buffer.len()
        if pending_size <= options.max_pending_output_bytes {
            self.output.append(self.response_buffer)
        }
        if !keep_alive { self.close_after_write = true }
        return ok(true)
    }

    fn dispatch(app: WebApplication,
                request: http.ServedRequest,
                options: ServerOptions,
                stats: ServerStats) -> Result<bool> {
        self.requests += 1
        stats.requests += 1
        if self.requests >= options.max_requests_per_connection {
            request.keep_alive = false
        }
        match app.handle(request, self.peer) {
            ok(context) => {
                let queued: Result<bool> = self.append_response(
                    context.response.status,
                    context.response.reason,
                    context.response.headers,
                    context.response.body,
                    request.keep_alive,
                    context.head_only,
                    options)
                let closed: Result<bool> = context.close()
                queued?
                closed?
                stats.responses += 1
            }
            err(problem) => {
                let status: int = if problem.kind == "bad_request" {
                    400
                } else { 500 }
                let reason: string = if status == 400 {
                    "Bad Request"
                } else { "Internal Server Error" }
                self.append_error(
                    status, reason, problem.msg, false, options)?
                stats.responses += 1
            }
        }
        return ok(true)
    }

    fn absorb(app: WebApplication,
              events: List<http.RequestEvent>,
              options: ServerOptions,
              stats: ServerStats) -> Result<bool> {
        for event: http.RequestEvent in events {
            match event {
                head(request) => {
                    self.building = new http.ServedRequest()
                    self.building.head = request
                    self.building.keep_alive = request.keep_alive
                    self.have_head = true
                }
                body(piece) => {
                    if self.building.body.len() + piece.len() > self.max_body {
                        self.append_error(
                            413, "Content Too Large",
                            "request body exceeds the configured limit",
                            false, options)?
                        self.close_after_write = true
                        return ok(false)
                    }
                    self.building.body.append(piece)
                }
                trailers(fields) => {
                    self.building.trailer_fields = fields
                }
                done(keep_alive) => {
                    self.building.keep_alive = keep_alive
                    let ready: http.ServedRequest = self.building
                    self.building = new http.ServedRequest()
                    self.have_head = false
                    self.dispatch(app, ready, options, stats)?
                }
                upgraded(request, remainder) => {
                    self.append_error(
                        400, "Bad Request",
                        "protocol upgrades are not enabled", false, options)?
                    self.close_after_write = true
                    return ok(false)
                }
            }
        }
        return ok(true)
    }

    fn read_ready(app: WebApplication,
                  options: ServerOptions,
                  stats: ServerStats) -> Result<bool> {
        for !self.close_after_write && !self.read_paused {
            match self.stream.try_read_into(self.read_buffer)? {
                none => { return ok(true) }
                some(count) => {
                    self.last_active_nanos = time.monotonic_nanos()
                    if count == 0 {
                        self.close_after_write = true
                        match self.parser.finish() {
                            ok(events) => {
                                self.absorb(app, events, options, stats)?
                            }
                            err(problem) => {
                                if self.have_head {
                                    self.append_error(
                                        400, "Bad Request", problem.msg,
                                        false, options)?
                                }
                            }
                        }
                        return ok(true)
                    }
                    match self.parser.feed_range(
                            self.read_buffer, 0, count) {
                        ok(events) => {
                            self.absorb(app, events, options, stats)?
                        }
                        err(problem) => {
                            self.append_error(
                                if problem.kind == "too_large" { 431 } else { 400 },
                                if problem.kind == "too_large" {
                                    "Request Header Fields Too Large"
                                } else { "Bad Request" },
                                problem.msg, false, options)?
                            self.close_after_write = true
                            return ok(false)
                        }
                    }
                }
            }
        }
        return ok(true)
    }

    fn write_ready() -> Result<bool> {
        for self.has_output() {
            match self.stream.try_write_from(
                    self.output, self.output_offset)? {
                none => { return ok(true) }
                some(count) => {
                    if count <= 0 {
                        return err("the connection accepted no output", "reset")
                    }
                    self.output_offset += count
                    self.last_active_nanos = time.monotonic_nanos()
                }
            }
        }
        self.compact_output()
        if self.read_paused && !self.close_after_write {
            self.read_paused = false
        }
        return ok(!self.close_after_write)
    }

    fn process(event: poll.Event,
               app: WebApplication,
               options: ServerOptions,
               stats: ServerStats) -> Result<bool> {
        if event.readable && !self.close_after_write {
            self.read_ready(app, options, stats)?
        }
        if event.writable || self.has_output() {
            if !self.write_ready()? { return ok(false) }
        }
        if event.error { return ok(false) }
        if event.hangup && !self.has_output() { return ok(false) }
        return ok(!self.close_after_write || self.has_output())
    }

    fn begin_shutdown() -> bool {
        self.close_after_write = true
        self.read_paused = true
        return self.has_output()
    }

    fn close() -> Result<bool> { return self.stream.close() }
}

/// One level-triggered HTTP/1.1 event loop.
pub unique class WebServer {
    app: WebApplication
    options: ServerOptions
    listener: net.TcpListener
    watch: poll.Poller
    stopping: Atomic<bool> = new Atomic<bool>(false)
    next_token: int = 1
    listener_live: bool = true
    resources_live: bool = true

    fn init(app: WebApplication,
            options: ServerOptions,
            move listener: net.TcpListener,
            move watch: poll.Poller) {
        self.app = app
        self.options = options
        self.listener = move listener
        self.watch = move watch
    }

    pub static fn bind(app: WebApplication,
                       options: ServerOptions) -> Result<WebServer> {
        options.validate()?
        let listener: net.TcpListener = net.TcpListener.bind_with_backlog(
            options.host, options.port, options.backlog)?
        listener.set_nonblocking(true)?
        let watch: poll.Poller = poll.Poller.open()?
        watch.add(listener.poll_handle(), 0, poll.Interest.read_only())?
        return ok(new WebServer(app, options, move listener, move watch))
    }

    pub fn port() -> Result<int> { return self.listener.port() }

    pub fn control() -> ServerControl {
        return ServerControl {
            stopping: self.stopping,
            signal: self.watch.wake_handle(),
        }
    }

    fn drop_connection(move connection: ServerConnection) {
        let ignored_watch: Result<bool> =
            self.watch.remove(connection.handle())
        let ignored_close: Result<bool> = connection.close()
    }

    fn accept_ready(connections: List<ServerConnection>,
                    tokens: List<int>,
                    stats: ServerStats) -> Result<bool> {
        for {
            let pending: Option<net.TcpStream> = self.listener.try_accept()?
            if pending.is_none() { break }
            let stream: net.TcpStream = (move pending).expect("accepted stream")
            if connections.len() >= self.options.max_connections {
                stats.rejected += 1
                let ignored: Result<bool> = stream.close()
                continue
            }
            stream.set_nonblocking(true)?
            let peer: net.Address = stream.peer_address()?
            let token: int = self.next_token
            self.next_token += 1
            self.watch.add(
                stream.poll_handle(), token, poll.Interest.read_only())?
            connections.push(new ServerConnection(
                move stream, peer, self.options))
            tokens.push(token)
            stats.accepted += 1
            if connections.len() > stats.active_peak {
                stats.active_peak = connections.len()
            }
        }
        return ok(true)
    }

    fn stop_accepting() {
        if !self.listener_live { return }
        let ignored_watch: Result<bool> =
            self.watch.remove(self.listener.poll_handle())
        let ignored_close: Result<bool> = self.listener.close()
        self.listener_live = false
    }

    fn close_resources() {
        if !self.resources_live { return }
        self.stop_accepting()
        let ignored_watch: Result<bool> = self.watch.close()
        let ignored_app: Result<bool> = self.app.close()
        self.resources_live = false
    }

    /// Blocks in the poller until `control().stop()` asks for shutdown.
    pub fn run() -> Result<ServerStats> {
        if !self.resources_live {
            return err("the server is closed", "closed")
        }
        var connections: List<ServerConnection> = []
        var tokens: List<int> = []
        let stats: ServerStats = new ServerStats()
        var draining: bool = false
        var deadline: int = 0

        for {
            if self.stopping.load(MemoryOrder.acquire) && !draining {
                draining = true
                deadline = time.monotonic_nanos() +
                    self.options.graceful_shutdown_ms * 1000000
                self.stop_accepting()
                let count: int = connections.len()
                for index: int in 0..count {
                    let connection: ServerConnection = connections.remove(0)
                    let token: int = tokens.remove(0)
                    if connection.begin_shutdown() {
                        self.watch.modify(
                            connection.handle(), token,
                            poll.Interest.write_only())?
                        connections.push(move connection)
                        tokens.push(token)
                    } else {
                        self.drop_connection(move connection)
                    }
                }
            }
            if draining && connections.len() == 0 { break }
            if draining && time.monotonic_nanos() >= deadline {
                for connections.len() != 0 {
                    let connection: ServerConnection = connections.remove(0)
                    tokens.remove(0)
                    self.drop_connection(move connection)
                }
                break
            }

            let events: List<poll.Event> = self.watch.wait(
                self.options.max_events,
                if draining { 50 } else { self.options.poll_timeout_ms })?
            for event: poll.Event in events {
                if event.token == 0 {
                    if !draining {
                        self.accept_ready(connections, tokens, stats)?
                    }
                    continue
                }
                match tokens.index_of(event.token) {
                    none => {}
                    some(index) => {
                        let connection: ServerConnection =
                            connections.remove(index)
                        tokens.remove(index)
                        var keep: bool = false
                        match connection.process(
                                event, self.app, self.options, stats) {
                            ok(active) => { keep = active }
                            err(problem) => {
                                stats.connection_errors += 1
                            }
                        }
                        if keep {
                            self.watch.modify(
                                connection.handle(), event.token,
                                connection.interest())?
                            connections.push(move connection)
                            tokens.push(event.token)
                        } else {
                            self.drop_connection(move connection)
                        }
                    }
                }
            }

            let now: int = time.monotonic_nanos()
            let count: int = connections.len()
            for index: int in 0..count {
                let connection: ServerConnection = connections.remove(0)
                let token: int = tokens.remove(0)
                if connection.idle(now, self.options.idle_timeout_ms) {
                    self.drop_connection(move connection)
                } else {
                    connections.push(move connection)
                    tokens.push(token)
                }
            }
        }
        self.close_resources()
        return ok(stats)
    }

    pub fn close() -> Result<bool> {
        if !self.resources_live { return err("the server is closed", "closed") }
        self.stopping.store(true, MemoryOrder.release)
        self.close_resources()
        return ok(true)
    }

    fn deinit() { self.close_resources() }
}
