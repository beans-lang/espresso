package espresso

import std.http
import std.net
import std.poll
import std.thread
import std.time

/// Bounds for the listener, parser, connections, bodies, and output queues.
pub class ServerOptions {
    pub host: string = "127.0.0.1"
    pub port: int = 8080
    pub backlog: int = 512
    pub max_connections: int = 10000
    pub max_events: int = 256
    // Short on purpose: a busy loop never reaches the timeout, and a parked
    // loop that wakes 40 times a second keeps the process out of the
    // platform's idle heuristics — macOS delays kevent wakeups by up to the
    // full timeout when most of a process's threads sit in long waits.
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
    context: Option<HttpContext> = none
    have_head: bool = false
    events: List<http.RequestEvent> = []
    read_buffer: Bytes
    output: Bytes = new Bytes(0)
    response_buffer: Bytes = new Bytes(0)
    output_offset: int = 0
    close_after_write: bool = false
    read_paused: bool = false
    watching_read: bool = true
    watching_write: bool = false
    requests: int = 0
    last_active_nanos: int
    max_body: int
    mail: LoopMailbox
    token: int
    // Which pending request a Completion must name to be applied. Bumped
    // whenever a pending request resolves, so late responders are no-ops.
    generation: int = 0
    pending: bool = false
    pending_since: int = 0
    pending_keep_alive: bool = true
    pending_head_only: bool = false
    // Parsed events that arrived behind a deferred request. They replay in
    // order once its response lands, so pipelining stays well-ordered.
    deferred_events: List<http.RequestEvent> = []

    fn init(move stream: net.TcpStream,
            peer: net.Address,
            options: ServerOptions,
            mail: LoopMailbox,
            token: int) {
        self.stream = move stream
        self.peer = peer
        self.mail = mail
        self.token = token
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
        // A pending connection is waiting on our own worker, not the peer;
        // the pending timeout governs it instead.
        if self.pending { return false }
        return now - self.last_active_nanos > timeout_ms * 1000000
    }

    fn pending_expired(now: int, timeout_ms: int) -> bool {
        if !self.pending { return false }
        return now - self.pending_since > timeout_ms * 1000000
    }

    fn interest() -> poll.Interest {
        let read: bool = !self.close_after_write && !self.read_paused
        let write: bool = self.has_output()
        return new poll.Interest(read, write)
    }

    fn interest_changed() -> bool {
        let read: bool = !self.close_after_write && !self.read_paused
        let write: bool = self.has_output()
        return read != self.watching_read || write != self.watching_write
    }

    fn remember_interest() {
        self.watching_read = !self.close_after_write && !self.read_paused
        self.watching_write = self.has_output()
    }

    fn watched() -> bool {
        return self.watching_read || self.watching_write
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

    // Parks this connection until a Completion answers the current request.
    fn begin_pending(keep_alive: bool, head_only: bool) {
        self.pending = true
        self.pending_since = time.monotonic_nanos()
        self.pending_keep_alive = keep_alive
        self.pending_head_only = head_only
        self.read_paused = true
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
                active.mail_generation = self.generation
                match app.handle_context(active) {
                    ok(_) => {
                        if active.deferred {
                            let closed: Result<bool> = active.close()
                            self.begin_pending(
                                active.request.keep_alive, active.head_only)
                            closed?
                        } else {
                            let queued: Result<bool> = self.append_response(
                                active.response.status,
                                active.response.reason,
                                active.response.headers,
                                active.response.body,
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
                        if active.deferred {
                            // A responder is already loose in the world; the
                            // connection must wait for it no matter how the
                            // pipeline itself ended.
                            let closed: Result<bool> = active.close()
                            self.begin_pending(
                                active.request.keep_alive, active.head_only)
                            closed?
                        } else {
                            let ignored: Result<bool> = active.close()
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
                }
            }
            none => {
                return err("request completed without a context", "state")
            }
        }
        return ok(true)
    }

    // One parsed request event. `ok(false)` means stop absorbing: the
    // connection is closing, or the current request just went pending.
    fn absorb_event(event: http.RequestEvent,
                    app: WebApplication,
                    options: ServerOptions,
                    stats: ServerStats) -> Result<bool> {
        match event {
            head(request) => {
                if self.context.is_none() {
                    let created: HttpContext = app.new_context(self.peer)
                    // Armed once per connection: mailbox and token never
                    // change, and the per-request generation is stamped by
                    // dispatch as a plain field write.
                    created.arm(self.mail, self.token, self.generation)
                    self.context = some(created)
                }
                self.have_head = true
                match self.context {
                    some(active) => {
                        match app.begin_request(active, request) {
                            ok(_) => {}
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
                if self.pending { return ok(false) }
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
            if !proceed {
                if self.pending {
                    // Events behind the pending request wait their turn.
                    for self.events.len() > position + 1 {
                        let parked: http.RequestEvent =
                            self.events.remove(position + 1)
                        self.deferred_events.push(move parked)
                    }
                }
                return ok(false)
            }
        }
        return ok(true)
    }

    // Applies one deferred completion. A stale payload — wrong generation,
    // or nothing pending — is dropped without effect.
    fn resolve_pending(move done: Completion,
                       app: WebApplication,
                       options: ServerOptions,
                       stats: ServerStats) -> Result<bool> {
        if !self.pending || done.generation != self.generation {
            return ok(true)
        }
        self.pending = false
        self.generation += 1
        let headers: http.Headers = new http.Headers()
        for index: int in 0..done.header_names.len() {
            headers.add(done.header_names[index], done.header_values[index])
        }
        if done.content_type != "" && !headers.has("Content-Type") {
            headers.add("Content-Type", done.content_type)
        }
        if app.server_header() != "" && !headers.has("Server") {
            headers.add("Server", app.server_header())
        }
        self.append_response(
            done.status, done.reason, headers, done.body,
            self.pending_keep_alive, self.pending_head_only, options)?
        stats.responses += 1
        return self.resume_after_pending(app, options, stats)
    }

    // Replays events parked behind a pending request, then reopens reads
    // once nothing pending or parked remains.
    fn resume_after_pending(app: WebApplication,
                            options: ServerOptions,
                            stats: ServerStats) -> Result<bool> {
        for !self.pending && !self.close_after_write &&
            self.deferred_events.len() > 0 {
            let parked: http.RequestEvent = self.deferred_events.remove(0)
            let proceed: bool = self.absorb_event(
                parked, app, options, stats)?
            if !proceed {
                if !self.pending { self.deferred_events.clear() }
                break
            }
        }
        if !self.pending && self.deferred_events.len() == 0 &&
           !self.close_after_write &&
           self.output.len() < options.max_pending_output_bytes / 2 {
            self.read_paused = false
        }
        return ok(true)
    }

    // The pending request took too long: answer 503 and close. The bump
    // makes any late responder for it a no-op.
    fn expire_pending(options: ServerOptions) -> Result<bool> {
        self.pending = false
        self.generation += 1
        self.deferred_events.clear()
        return self.append_error(
            503, "Service Unavailable",
            "the deferred response timed out", false, options)
    }

    fn read_ready(now: int,
                  app: WebApplication,
                  options: ServerOptions,
                  stats: ServerStats) -> Result<bool> {
        for !self.close_after_write && !self.read_paused {
            match self.stream.try_read_into(self.read_buffer)? {
                none => { return ok(true) }
                some(count) => {
                    self.last_active_nanos = now
                    if count == 0 {
                        self.close_after_write = true
                        self.events.clear()
                        match self.parser.finish_into(self.events) {
                            ok(_) => {
                                self.absorb(app, options, stats)?
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
                    self.events.clear()
                    match self.parser.feed_range_into(
                            self.read_buffer, 0, count, self.events) {
                        ok(_) => {
                            self.absorb(app, options, stats)?
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

    fn write_ready(now: int) -> Result<bool> {
        for self.has_output() {
            match self.stream.try_write_from(
                    self.output, self.output_offset)? {
                none => { return ok(true) }
                some(count) => {
                    if count <= 0 {
                        return err("the connection accepted no output", "reset")
                    }
                    self.output_offset += count
                    self.last_active_nanos = now
                }
            }
        }
        self.compact_output()
        // A flushed queue reopens reads only when nothing is pending or
        // parked — otherwise new requests would overtake a deferred one.
        if self.read_paused && !self.close_after_write &&
           !self.pending && self.deferred_events.len() == 0 {
            self.read_paused = false
        }
        return ok(!self.close_after_write)
    }

    fn process(event: poll.Event,
               now: int,
               app: WebApplication,
               options: ServerOptions,
               stats: ServerStats) -> Result<bool> {
        if event.readable && !self.close_after_write {
            self.read_ready(now, app, options, stats)?
        }
        if event.writable || self.has_output() {
            if !self.write_ready(now)? { return ok(false) }
        }
        if event.error { return ok(false) }
        // A half-closed peer may still be waiting for a deferred response.
        if event.hangup && !self.has_output() && !self.pending {
            return ok(false)
        }
        return ok(self.pending || !self.close_after_write ||
                  self.has_output())
    }

    fn begin_shutdown() -> bool {
        self.close_after_write = true
        self.read_paused = true
        return self.has_output() || self.pending
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
    intake: Option<Mutex<List<net.TcpStream>>> = none
    // Deferred responses from worker threads land here; the loop drains it
    // on every wakeup, exactly like the intake queue.
    mail: Mutex<List<Completion>> = new Mutex([])
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
        return WebServer.adopt(app, options, move listener)
    }

    /// Wraps an already-bound listener — the road `serve` takes to give
    /// every worker its own SO_REUSEPORT accept loop.
    pub static fn adopt(app: WebApplication,
                        options: ServerOptions,
                        move listener: net.TcpListener) -> Result<WebServer> {
        options.validate()?
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

    fn mailbox() -> LoopMailbox {
        return LoopMailbox {
            completions: self.mail,
            signal: self.watch.wake_handle(),
        }
    }

    // Reprograms the poller to a connection's current interest. A pending
    // connection wants neither reads nor writes, and the poller refuses an
    // empty registration, so "nothing" is expressed by deregistering; the
    // completion arrives by wake, never by event.
    fn update_watch(connection: ServerConnection,
                    token: int) -> Result<bool> {
        if !connection.interest_changed() { return ok(true) }
        let want: poll.Interest = connection.interest()
        if want.read || want.write {
            if connection.watched() {
                self.watch.modify(connection.handle(), token, want)?
            } else {
                self.watch.add(connection.handle(), token, want)?
            }
        } else if connection.watched() {
            self.watch.remove(connection.handle())?
        }
        connection.remember_interest()
        return ok(true)
    }

    /// Accepts connections handed over by an acceptor thread. The acceptor
    /// pushes streams under the lock and then pokes `control().signal`
    /// through `poll.wake`; this loop drains the queue on every wakeup.
    pub fn set_intake(queue: Mutex<List<net.TcpStream>>) {
        self.intake = some(queue)
    }

    fn drop_connection(move connection: ServerConnection) {
        let ignored_watch: Result<bool> =
            self.watch.remove(connection.handle())
        let ignored_close: Result<bool> = connection.close()
    }

    fn drop_connection_at(connections: List<ServerConnection>,
                          tokens: List<int>,
                          token_indexes: Map<int, int>,
                          index: int) {
        let token: int = tokens.remove(index)
        let connection: ServerConnection = connections.remove(index)
        let removed: bool = token_indexes.remove(token)
        var shifted: int = index
        for shifted < tokens.len() {
            token_indexes[tokens[shifted]] = shifted
            shifted += 1
        }
        self.drop_connection(move connection)
    }

    // Takes ownership of one connected stream. A failure here is the
    // stream's problem, never the server's: the stream is closed, counted,
    // and the loop carries on.
    fn admit(move stream: net.TcpStream,
             connections: List<ServerConnection>,
             tokens: List<int>,
             token_indexes: Map<int, int>,
             stats: ServerStats) {
        if connections.len() >= self.options.max_connections {
            stats.rejected += 1
            let ignored: Result<bool> = stream.close()
            return
        }
        var ready: bool = true
        match stream.set_nonblocking(true) {
            ok(_) => {}
            err(_) => { ready = false }
        }
        let ignored_nodelay: Result<bool> = stream.set_nodelay(true)
        var peer: net.Address = new net.Address("", 0)
        if ready {
            match stream.peer_address() {
                ok(address) => { peer = address }
                err(_) => { ready = false }
            }
        }
        if !ready {
            stats.connection_errors += 1
            let ignored: Result<bool> = stream.close()
            return
        }
        let token: int = self.next_token
        self.next_token += 1
        match self.watch.add(
                stream.poll_handle(), token, poll.Interest.read_only()) {
            ok(_) => {}
            err(_) => {
                stats.connection_errors += 1
                let ignored: Result<bool> = stream.close()
                return
            }
        }
        connections.push(new ServerConnection(
            move stream, peer, self.options, self.mailbox(), token))
        tokens.push(token)
        token_indexes[token] = connections.len() - 1
        stats.accepted += 1
        if connections.len() > stats.active_peak {
            stats.active_peak = connections.len()
        }
    }

    fn accept_ready(connections: List<ServerConnection>,
                    tokens: List<int>,
                    token_indexes: Map<int, int>,
                    stats: ServerStats) -> Result<bool> {
        for {
            let pending: Option<net.TcpStream> = self.listener.try_accept()?
            if pending.is_none() { break }
            self.admit((move pending).expect("accepted stream"),
                       connections, tokens, token_indexes, stats)
        }
        return ok(true)
    }

    fn drain_intake(connections: List<ServerConnection>,
                    tokens: List<int>,
                    token_indexes: Map<int, int>,
                    stats: ServerStats) {
        match self.intake {
            some(queue) => {
                var handed: List<net.TcpStream> = []
                queue.with_lock(fn(waiting: List<net.TcpStream>) {
                    for {
                        let next: Option<net.TcpStream> = waiting.pop()
                        if next.is_none() { break }
                        handed.push((move next).expect("handed stream"))
                    }
                })
                for {
                    let next: Option<net.TcpStream> = handed.pop()
                    if next.is_none() { break }
                    self.admit((move next).expect("intake stream"),
                               connections, tokens, token_indexes, stats)
                }
            }
            none => {}
        }
    }

    // Applies every deferred response waiting in the mailbox. Payloads for
    // connections that died in the meantime are dropped on the floor.
    fn drain_completions(now: int,
                         connections: List<ServerConnection>,
                         tokens: List<int>,
                         token_indexes: Map<int, int>,
                         stats: ServerStats) -> Result<bool> {
        var landed: List<Completion> = []
        self.mail.with_lock(fn(waiting: List<Completion>) {
            for {
                let next: Option<Completion> = waiting.pop()
                if next.is_none() { break }
                landed.push((move next).expect("completion"))
            }
        })
        for landed.len() > 0 {
            let done: Completion = landed.pop().expect("completion")
            match token_indexes.get(done.token) {
                none => {}
                some(index) => {
                    var keep: bool = true
                    match connections[index].resolve_pending(
                            move done, self.app, self.options, stats) {
                        ok(_) => {}
                        err(problem) => {
                            stats.connection_errors += 1
                            keep = false
                        }
                    }
                    // Push the response toward the peer right away instead
                    // of waiting one poll cycle for a writable event.
                    if keep && connections[index].has_output() {
                        match connections[index].write_ready(now) {
                            ok(alive) => { keep = alive }
                            err(problem) => {
                                stats.connection_errors += 1
                                keep = false
                            }
                        }
                    }
                    if keep {
                        keep = connections[index].pending ||
                               !connections[index].close_after_write ||
                               connections[index].has_output()
                    }
                    if keep {
                        self.update_watch(connections[index], tokens[index])?
                    } else {
                        self.drop_connection_at(
                            connections, tokens, token_indexes, index)
                    }
                }
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
        var token_indexes: Map<int, int> = {}
        let stats: ServerStats = new ServerStats()
        var draining: bool = false
        var deadline: int = 0
        var idle_sweep_ms: int = if self.options.idle_timeout_ms < 1000 {
            self.options.idle_timeout_ms
        } else { 1000 }
        if self.options.pending_timeout_ms < idle_sweep_ms {
            idle_sweep_ms = self.options.pending_timeout_ms
        }
        var next_idle_sweep: int = time.monotonic_nanos() +
            idle_sweep_ms * 1000000

        for {
            if self.stopping.load(MemoryOrder.acquire) && !draining {
                draining = true
                deadline = time.monotonic_nanos() +
                    self.options.graceful_shutdown_ms * 1000000
                self.stop_accepting()
                token_indexes.clear()
                let count: int = connections.len()
                for index: int in 0..count {
                    let connection: ServerConnection = connections.remove(0)
                    let token: int = tokens.remove(0)
                    if connection.begin_shutdown() {
                        // A pending connection watches nothing until its
                        // completion arrives by wake; the rest flush writes.
                        self.update_watch(connection, token)?
                        token_indexes[token] = connections.len()
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
                token_indexes.clear()
                break
            }

            let events: List<poll.Event> = self.watch.wait(
                self.options.max_events,
                if draining { 50 } else { self.options.poll_timeout_ms })?
            let batch_now: int = time.monotonic_nanos()
            if !draining {
                self.drain_intake(connections, tokens, token_indexes, stats)
            }
            // Deferred responses land even while draining: a graceful stop
            // waits for in-flight work before closing those connections.
            self.drain_completions(
                batch_now, connections, tokens, token_indexes, stats)?
            for event: poll.Event in events {
                if event.token == 0 {
                    if !draining {
                        self.accept_ready(
                            connections, tokens, token_indexes, stats)?
                    }
                    continue
                }
                match token_indexes.get(event.token) {
                    none => {}
                    some(index) => {
                        var keep: bool = false
                        match connections[index].process(
                                event, batch_now, self.app, self.options,
                                stats) {
                            ok(active) => { keep = active }
                            err(problem) => {
                                stats.connection_errors += 1
                            }
                        }
                        if keep {
                            self.update_watch(
                                connections[index], event.token)?
                        } else {
                            self.drop_connection_at(
                                connections, tokens, token_indexes, index)
                        }
                    }
                }
            }

            let now: int = time.monotonic_nanos()
            if !draining && now >= next_idle_sweep {
                var index: int = 0
                for index < connections.len() {
                    if connections[index].pending_expired(
                            now, self.options.pending_timeout_ms) {
                        var kept: bool = true
                        match connections[index].expire_pending(
                                self.options) {
                            ok(_) => {}
                            err(problem) => { kept = false }
                        }
                        if kept {
                            stats.responses += 1
                            self.update_watch(
                                connections[index], tokens[index])?
                            index += 1
                        } else {
                            stats.connection_errors += 1
                            self.drop_connection_at(
                                connections, tokens, token_indexes, index)
                        }
                    } else if connections[index].idle(
                            now, self.options.idle_timeout_ms) {
                        self.drop_connection_at(
                            connections, tokens, token_indexes, index)
                    } else {
                        index += 1
                    }
                }
                next_idle_sweep = now + idle_sweep_ms * 1000000
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
