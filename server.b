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

// The size a released output queue is reserved back to — the same reserve a
// connection starts with. A queue that outgrew its bound is replaced by a
// buffer this size rather than kept, so an idle keep-alive connection holds a
// kilobyte and not the largest batch it ever framed.
const output_queue_reserve: int = 1024

// What the three write paths say if they are ever reached after an upgrade
// endpoint took the socket. Nothing should reach them — the connection loop
// ends on the same event that hands the socket over, and the output queue is
// pushed before the hand-off — so this is the guard that turns a would-be
// use-after-move into a named error instead of an index panic.
const handed_off_detail: string =
    "this connection was handed to another protocol and can no longer be written"


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
    /// The most framed response bytes a connection may hold in its output
    /// queue before it pushes them to the peer.
    ///
    /// One read can carry many pipelined requests, all framed before the
    /// read loop's flush; unbounded, the queue grows to the whole batch and
    /// keeps that memory for the connection's life — a client turns a few
    /// kilobytes of requests into megabytes of buffer. Reaching the bound
    /// flushes early instead: one extra write per bound-worth of output,
    /// invisible to the client since the queue only ever ends on a response
    /// boundary, so pipelined order holds.
    ///
    /// Default: one read buffer's worth, 64 KiB (~500 small responses, so
    /// batching still pays off), and four times `vectored_body_min` — the
    /// point past which a batch of small bodies is worth a write of its
    /// own.
    pub max_queued_output_bytes: int = 65536
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
           self.max_queued_output_bytes <= 0 ||
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
    /// How many times a request body that had outgrown one read was released
    /// after its response, rather than kept for the connection's life.
    pub request_buffers_released: int = 0
    /// How many request bodies larger than one read were sized to their
    /// declared length up front, so their pieces filled one allocation instead
    /// of regrowing it.
    pub request_bodies_presized: int = 0
    /// The largest an output queue grew before it was pushed to its peer, over
    /// every connection of this run. It is bounded by `max_queued_output_bytes`
    /// plus the one response that crossed the bound.
    pub output_queue_peak: int = 0
    /// How many times a connection pushed its output queue mid-batch because it
    /// had reached `max_queued_output_bytes`, rather than at the end of the
    /// batch it was framing.
    pub output_queue_flushes: int = 0
    /// How many times an output queue that had outgrown
    /// `max_queued_output_bytes` was released after its flush, rather than kept
    /// for the connection's life.
    pub output_buffers_released: int = 0
    /// How many connections were handed to another protocol through an
    /// upgrade endpoint. Such a connection produces no `responses` entry —
    /// the 101 is written by the protocol library, not by this server.
    pub upgrades: int = 0
    /// How many responses went out as a chunked stream rather than a framed
    /// buffer. They are counted in `responses` too.
    pub streamed: int = 0

    pub fn init() {}
}

// A byte-substring search: the index in `haystack` where `needle` begins at or
// after `start`, or -1. Used when a head-cache entry is built, to locate the
// two spans that vary between responses, and by the multipart parser, to find
// the next boundary in what has arrived.
fn find_bytes(haystack: Bytes, needle: string, start: int) -> int {
    let n: int = haystack.len()
    let m: int = needle.len()
    if m == 0 { return start }
    var i: int = if start < 0 { 0 } else { start }
    for i + m <= n {
        var j: int = 0
        var matched: bool = true
        for j < m {
            if haystack.get(i + j) != needle.byte_at(j) {
                matched = false
                break
            }
            j += 1
        }
        if matched { return i }
        i += 1
    }
    return -1
}

// A per-connection cache of one response head: a connection answering the
// same shape repeatedly frames it by copying two spans and patching the
// Date, instead of re-validating headers and rebuilding the head each time.
//
// The cached bytes are std.http's own — built by calling
// `encode_response_head_append` with body length 0 — so the head is
// byte-for-byte what the plain path produces, by construction. Only two
// spans vary between responses of one shape (the Content-Length digits and
// the 29-byte IMF-fixdate Date), located once at build time by searching
// the produced bytes. If std.http ever changes its head layout, the cache
// rebuilds and stays identical automatically; the only risk is the two
// build-time searches missing their substrings, which simply declines the
// cache and falls back to the plain path.
pub class ResponseHeadCache {
    valid: bool = false
    key_status: int = 0
    key_reason: string = ""
    key_ctype: string = ""
    key_alive: bool = false
    // "HTTP/1.1 <status> <reason>\r\nContent-Length: "
    prefix: Bytes = new Bytes(0)
    // "\r\n<Connection?><Content-Type><Server?>Date: <29 bytes>\r\n\r\n"
    suffix: Bytes = new Bytes(0)
    // Offset of the 29-byte Date value within `suffix`.
    date_off: int = -1
    // The wall-second the cached Date bytes are for.
    stamped_second: int = -1

    pub fn init() {}

    // Appends the framed head for this response to `out`, reusing the cached
    // entry when the shape matches and rebuilding it when it does not. Returns
    // false (appending nothing) when the response cannot be cached, so the
    // caller frames it the plain way. `headers` must be the response's standard
    // headers (Content-Type, and Server if opted in) with no custom header and
    // no Date; `date_text` is the current IMF-fixdate and `second` its wall
    // second.
    pub fn frame_into(out: Bytes,
                      status: int, reason: string, content_type: string,
                      headers: http.Headers, keep_alive: bool, body_len: int,
                      date_text: string, second: int) -> Result<bool> {
        if !self.valid || self.key_status != status ||
           self.key_alive != keep_alive || self.key_ctype != content_type ||
           self.key_reason != reason {
            let built: bool = self.build(
                status, reason, content_type, headers, keep_alive, date_text)?
            if !built { return ok(false) }
            self.stamped_second = second
        }
        if second != self.stamped_second {
            self.suffix.copy_from(Bytes.from(date_text), self.date_off)
            self.stamped_second = second
        }
        out.append(self.prefix)
        out.append_int_text(body_len)
        out.append(self.suffix)
        return ok(true)
    }

    fn build(status: int, reason: string, content_type: string,
             headers: http.Headers, keep_alive: bool,
             date_text: string) -> Result<bool> {
        // Only Content-Type and an optional Server may stand before the Date
        // this adds; anything else means a non-standard header slipped past the
        // response's custom flag, so decline rather than cache a wrong head.
        if headers.count() == 0 || headers.count() > 2 { return ok(false) }
        if headers.name_at(0) != "Content-Type" { return ok(false) }
        let temp: http.Headers = new http.Headers()
        for index: int in 0..headers.count() {
            temp.add(headers.name_at(index), headers.value_at(index))
        }
        temp.add("Date", date_text)
        let buf: Bytes = new Bytes(0)
        let forbidden: bool = http.encode_response_head_append(
            buf, status, reason, temp, 0, keep_alive)?
        // A body-forbidden status has no Content-Length line to splice.
        if forbidden { return ok(false) }
        let cl_at: int = find_bytes(buf, "Content-Length: ", 0)
        if cl_at < 0 { return ok(false) }
        // The placeholder length is exactly "0"; a real response's digits are
        // written in its place and the suffix follows it.
        let digits_at: int = cl_at + 16
        if digits_at >= buf.len() || buf.get(digits_at) != 48 { return ok(false) }
        let suffix_at: int = digits_at + 1
        let date_label_at: int = find_bytes(buf, "Date: ", suffix_at)
        if date_label_at < 0 { return ok(false) }
        let date_val_at: int = date_label_at + 6
        // A fixed-width IMF-fixdate is 29 bytes and ends in CRLF; patching in
        // place is only safe if that is exactly what was produced.
        if date_val_at + 31 > buf.len() { return ok(false) }
        if buf.get(date_val_at + 29) != 13 || buf.get(date_val_at + 30) != 10 {
            return ok(false)
        }
        self.prefix = buf.slice(0, digits_at)
        self.suffix = buf.slice(suffix_at, buf.len())
        self.date_off = date_val_at - suffix_at
        self.valid = true
        self.key_status = status
        self.key_reason = reason
        self.key_ctype = content_type
        self.key_alive = keep_alive
        return ok(true)
    }
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

// Runs an upgrade handler on a child fiber, for the reason shielded_handle
// exists: connection_main owns this connection's ledger entry, and a panic
// that abandoned its frames would strand a descriptor the graceful sweep
// still reaches for. The socket has already been given away by the time this
// is called, so a contained panic costs this one connection and nothing else.
fn shielded_upgrade(handler: UpgradeHandler,
                    context: HttpContext,
                    head: http.Request,
                    move stream: net.TcpStream) -> Result<bool> {
    let ran: Brew<Result<bool>> =
        brew handler.upgrade(context, head, move stream)
    match ran.join() {
        ok(outcome) => { return outcome }
        err(problem) => { return err(problem.msg, problem.kind) }
    }
}

// One connection's whole life is owned by one fiber: reads park in the
// netpoller, writes flush inline, and a deferred request waits right here in
// request order.
//
// `ConnectionIo` is everything a response is written through: the socket
// and the queue in front of it. It is its own class, ordinary and
// aliasable, because a streamed response is written by the handler's own
// fiber through `context.begin_stream()`, and a handler cannot reach a
// `unique` ServerConnection. The connection and the stream writer therefore
// share one socket and one queue, so the ordering rule that keeps
// pipelined responses in order is one rule, not two.
class ConnectionIo {
    // The socket, parked in a one-slot list rather than a plain field. A
    // field of a move-only type cannot be moved out of — the language names
    // the way around it: "field and index moves need consuming accessors
    // such as List `remove`" (beans spec/SYNTAX.md) — and an upgrade
    // endpoint takes the socket by value, for keeps. `remove` yields the
    // stream and empties the list, which doubles as the flag: empty means
    // this connection no longer owns anything to read, write or close.
    socket: List<net.TcpStream> = []
    output: Bytes = new Bytes(0)
    // options.max_queued_output_bytes, held here because every flush consults
    // it and the flush paths sit below the layer that carries ServerOptions.
    max_queued: int
    // The run's counters. They are held here rather than passed to every
    // flush because a streamed response is flushed by the handler's own
    // fiber, through a writer that has no ServerStats to pass — and the queue
    // bookkeeping (peak, released) must count that flush too, or a streamed
    // response would quietly skip the accounting every other response pays.
    stats: ServerStats
    // The RFC 9110 Date value, cached per wall-clock second — see http_date().
    // One fiber is the sole toucher of a connection, so the cache needs no
    // lock and never crosses a thread.
    date_text: string = ""
    date_second: int = -1

    fn init(move stream: net.TcpStream,
            max_queued: int,
            stats: ServerStats) {
        self.socket.push(move stream)
        self.output.reserve(output_queue_reserve)
        self.max_queued = max_queued
        self.stats = stats
    }

    fn has_output() -> bool { return self.output.len() > 0 }

    // True while this connection still owns its socket. It stops being true
    // exactly once, when an upgrade endpoint takes it.
    fn owns_socket() -> bool { return self.socket.len() != 0 }

    fn hand_off() -> net.TcpStream { return self.socket.remove(0) }

    fn arm_timeouts(read_ms: int, write_ms: int) -> Result<bool> {
        if !self.owns_socket() { return err(handed_off_detail, "upgraded") }
        return self.socket[0].set_timeouts(read_ms, write_ms)
    }

    fn read_waiting(buffer: Bytes) -> Result<int> {
        if !self.owns_socket() { return err(handed_off_detail, "upgraded") }
        return self.socket[0].read_into_waiting(buffer)
    }

    // The RFC 9110 Date value for a response framed right now, as IMF-fixdate
    // in GMT — the only form a sender may generate. Espresso MUST send it on
    // 2xx/3xx/4xx and MAY on 1xx/5xx; since it emits no 1xx, stamping every
    // response is the simplest rule that's correct everywhere, applied at
    // the one layer that reaches a socket (append_response/append_error/
    // begin_stream).
    //
    // Formatting — a civil-time conversion plus allocations — is cached and
    // reused per wall-clock second. The clock is still read once per
    // response (a cheap vDSO `clock_gettime`), so the value is never stale:
    // a response crossing a second boundary reformats before it sends.
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

    // Ends a flush: the queue is empty again, and its buffer is kept only if
    // it is no larger than the connection is allowed to queue.
    //
    // `resize(0)` frees no pages, so an unbounded queue would hold that
    // memory for the connection's life — the same trap `release_large_body`
    // closes on the request body. An ordinary connection stays under the
    // bound and never reallocates, keeping the buffer reuse that makes small
    // pipelined responses cheap; the rare one that outgrows it — a batch
    // past the bound, or one oversized head — pays one allocation and hands
    // the memory back.
    fn finish_flush() {
        let sent: int = self.output.len()
        if sent > self.stats.output_queue_peak {
            self.stats.output_queue_peak = sent
        }
        if sent > self.max_queued {
            self.output = new Bytes(0)
            self.output.reserve(output_queue_reserve)
            self.stats.output_buffers_released += 1
            return
        }
        self.output.resize(0)
    }

    // The one write loop. Everything this connection sends goes through it —
    // the queue, a large body beside its head, every streamed chunk — so
    // "a short write is retried and backpressure parks this fiber" is one
    // rule with one implementation. `write_from` parks in the netpoller when
    // the peer's window is full; it never spins.
    fn push_all(buffer: Bytes) -> Result<bool> {
        if !self.owns_socket() { return err(handed_off_detail, "upgraded") }
        var offset: int = 0
        for offset < buffer.len() {
            match self.socket[0].write_from(buffer, offset) {
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
        return ok(true)
    }

    // The two-buffer write loop: a head and its payload sent as one pair,
    // the payload never entering a buffer. Every body-beside-head send uses
    // it — a large buffered response, every streamed chunk — so the
    // short-write retry and the backpressure park are one rule, not two.
    //
    // The head goes out in front of the payload in the same write, which
    // keeps pipelined responses in order by construction: nothing framed
    // before this can be overtaken, and nothing behind it can be framed
    // until this returns.
    fn push_pair(head: Bytes, body: Bytes) -> Result<bool> {
        if !self.owns_socket() { return err(handed_off_detail, "upgraded") }
        var offset: int = 0
        let total: int = head.len() + body.len()
        for offset < total {
            match self.socket[0].write_vectored(head, body, offset) {
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
        return ok(true)
    }

    // The string twin of push_pair. write_vectored_text takes the string's
    // bytes directly, so a large text body is neither copied into a response
    // buffer nor staged in a per-send one — the copy the old path made, and
    // the allocator high-water 32 of those concurrent copies set, are both
    // gone.
    fn push_pair_text(head: Bytes, text: string) -> Result<bool> {
        if !self.owns_socket() { return err(handed_off_detail, "upgraded") }
        var offset: int = 0
        let total: int = head.len() + text.len()
        for offset < total {
            match self.socket[0].write_vectored_text(head, text, offset) {
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
        return ok(true)
    }

    // Pushes the whole output queue to the peer, parking on backpressure.
    fn flush() -> Result<bool> {
        self.push_all(self.output)?
        self.finish_flush()
        return ok(true)
    }

    // Sends the queued output and this response's body as one pair, without
    // the body ever entering the queue.
    fn flush_with_body(body: Bytes) -> Result<bool> {
        self.push_pair(self.output, body)?
        self.finish_flush()
        return ok(true)
    }

    // The string twin of flush_with_body.
    fn flush_with_text(text: string) -> Result<bool> {
        self.push_pair_text(self.output, text)?
        self.finish_flush()
        return ok(true)
    }

    // Closing a connection whose socket went to another protocol is a
    // no-op, not an error: the handler owns that descriptor now and closing
    // it here would shut a live conversation — or, worse, a descriptor the
    // kernel has since reissued to someone else.
    fn close() -> Result<bool> {
        if !self.owns_socket() { return ok(true) }
        return self.socket[0].close()
    }
}

unique class ServerConnection {
    io: ConnectionIo
    peer: net.Address
    parser: http.RequestParser
    context: Option<HttpContext> = none
    have_head: bool = false
    // Set when the head just parsed asked to switch protocols. The parser
    // still reports `done` for such a message — it emits head, done and
    // upgraded together, in that order, in one batch however the bytes were
    // split — and dispatching that `done` would serve the handshake as an
    // ordinary GET and frame a response onto a connection that is about to
    // belong to another protocol. So `done` is skipped and the `upgraded`
    // event that follows does the work.
    upgrade_pending: bool = false
    events: List<http.RequestEvent> = []
    read_buffer: Bytes
    close_after_write: bool = false
    requests: int = 0
    max_body: int
    // The head most recently adopted by the context. It goes back to the
    // parser for reuse only when the next head has replaced every alias to
    // it — the swap in absorb_event's head arm.
    previous_head: Option<http.Request> = none
    // Caches this connection's last response head so a repeated shape is framed
    // by copying two spans and patching the Date — see ResponseHeadCache.
    head_cache: ResponseHeadCache = new ResponseHeadCache()

    fn init(move stream: net.TcpStream,
            peer: net.Address,
            options: ServerOptions,
            stats: ServerStats) {
        self.io = new ConnectionIo(
            move stream, options.max_queued_output_bytes, stats)
        self.peer = peer
        let limits: http.Limits = new http.Limits()
        limits.max_header_count = options.max_header_count
        limits.max_header_bytes = options.max_header_bytes
        limits.max_target_bytes = options.max_target_bytes
        limits.max_head_span_bytes = options.max_head_span_bytes
        self.parser = http.RequestParser.with_limits(limits)
        self.read_buffer = new Bytes(options.read_buffer_bytes)
        self.max_body = options.max_body_bytes
    }

    // Frames a finished response, in whichever form it carries its payload.
    // Neither form copies the payload into a per-connection buffer: a small one
    // is appended to the output queue (which keeps pipelined responses batched),
    // a large one is sent beside its head with one vectored write.
    fn append_response_from(response: HttpResponse,
                            keep_alive: bool,
                            head_only: bool,
                            options: ServerOptions,
                            stats: ServerStats) -> Result<bool> {
        // Fast path: a response with only standard headers and a known content
        // type reuses this connection's cached head, framed by copying two
        // spans and patching the Date rather than re-validating the headers and
        // rebuilding the head. HEAD, custom-header, no-content-type, and
        // over-limit responses fall through to the plain path unchanged.
        if !head_only && !response.has_custom_header() &&
           response.content_type() != "" &&
           response.body_len() <= options.max_response_body_bytes {
            let alive: bool = keep_alive && !self.close_after_write
            let body_len: int = response.body_len()
            let date: string = self.io.http_date()
            match self.head_cache.frame_into(
                    self.io.output, response.status, response.reason,
                    response.content_type(), response.headers, alive, body_len,
                    date, self.io.date_second) {
                ok(cached) => {
                    if cached {
                        if !keep_alive { self.close_after_write = true }
                        if response.is_text_body() {
                            if body_len >= vectored_body_min {
                                return self.io.flush_with_text(
                                    response.text_payload())
                            }
                            self.io.output.append_string(response.text_payload())
                            return ok(true)
                        }
                        if body_len >= vectored_body_min {
                            return self.io.flush_with_body(response.body)
                        }
                        self.io.output.append(response.body)
                        return ok(true)
                    }
                }
                err(problem) => { return err(problem.msg, problem.kind) }
            }
        }
        if response.is_text_body() {
            return self.append_response_text(
                response.status, response.reason, response.headers,
                response.text_payload(), keep_alive, head_only, options, stats)
        }
        return self.append_response_bytes(
            response.status, response.reason, response.headers,
            response.body, keep_alive, head_only, options, stats)
    }

    fn append_response_bytes(status: int,
                             reason: string,
                             headers: http.Headers,
                             body: Bytes,
                             keep_alive: bool,
                             head_only: bool,
                             options: ServerOptions,
                             stats: ServerStats) -> Result<bool> {
        if body.len() > options.max_response_body_bytes {
            return self.append_error(
                500, "Internal Server Error",
                "response body exceeds the configured limit", false, options)
        }
        // RFC 9110 §6.6.1: stamp Date unless the handler set its own (the
        // lookup is case-insensitive), so it is never emitted twice.
        if !headers.has("Date") {
            headers.add("Date", self.io.http_date())
        }
        let alive: bool = keep_alive && !self.close_after_write
        // A HEAD response is the head. Framing the whole response and then
        // cutting the body off the end copied every byte of it first — a
        // megabyte, on the static route — to reach a buffer it was about to
        // be removed from.
        if head_only {
            http.encode_response_head_append(
                self.io.output, status, reason, headers, body.len(), alive)?
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
                self.io.output, status, reason, headers, body.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            if forbidden { return ok(true) }
            return self.io.flush_with_body(body)
        }
        http.encode_response_append(
            self.io.output, status, reason, headers, body, alive)?
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
                            options: ServerOptions,
                            stats: ServerStats) -> Result<bool> {
        if text.len() > options.max_response_body_bytes {
            return self.append_error(
                500, "Internal Server Error",
                "response body exceeds the configured limit", false, options)
        }
        if !headers.has("Date") {
            headers.add("Date", self.io.http_date())
        }
        let alive: bool = keep_alive && !self.close_after_write
        if head_only {
            http.encode_response_head_append(
                self.io.output, status, reason, headers, text.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            return ok(true)
        }
        if text.len() >= vectored_body_min {
            let forbidden: bool = http.encode_response_head_append(
                self.io.output, status, reason, headers, text.len(), alive)?
            if !keep_alive { self.close_after_write = true }
            if forbidden { return ok(true) }
            return self.io.flush_with_text(text)
        }
        // Small: frame the head, then append the string's bytes into the output
        // queue — the same wire bytes and the same single copy a Bytes body
        // takes through encode_response_append, but read from the handler's
        // string so nothing is staged in a response buffer first.
        let forbidden: bool = http.encode_response_head_append(
            self.io.output, status, reason, headers, text.len(), alive)?
        if !forbidden { self.io.output.append_string(text) }
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
        // RFC 9110 §6.6.1: an error response is 4xx or 5xx; a 4xx is a MUST.
        headers.add("Date", self.io.http_date())
        let body: Bytes = Bytes.from(detail)
        http.encode_response_append(
            self.io.output, status, reason, headers, body, keep_alive)?
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
                                keep_alive, head_only, options, stats)?
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
                        } else if active.is_streaming() {
                            self.end_stream(active, true, stats)?
                        } else {
                            let queued: Result<bool> =
                                self.append_response_from(
                                    active.response,
                                    active.request.keep_alive,
                                    active.head_only,
                                    options, stats)
                            let closed: Result<bool> = active.close()
                            queued?
                            closed?
                            stats.responses += 1
                        }
                    }
                    err(problem) => {
                        // Every failure reaching the shield's join — a
                        // contained panic, or an error handle_context could
                        // not render — is worth a record, deferred or not.
                        // Log it once here, with the trace id the client
                        // will see, before the response is decided: this is
                        // the record the generic production message
                        // promises. RequestLog cannot fill this role — it
                        // runs inside the pipeline, which a panic unwinds
                        // straight past.
                        app.record_failure(active, problem.msg)
                        if active.is_streaming() {
                            // The head is on the wire and the body is
                            // half-written; leave it unterminated and close.
                            self.end_stream(active, false, stats)?
                            return ok(true)
                        }
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
                            // Connection policy: a handler error (a returned
                            // `err`, or a contained panic at the shield's
                            // join) is fatal to the connection —
                            // append_response is told keep_alive=false, so
                            // this is the connection's last response and it
                            // closes after. Deliberate: it bounds anything a
                            // half-finished request left on the reused
                            // HttpContext, and anything a panic would strand
                            // on a platform without the runtime unwind
                            // (Windows; see README), to this one connection
                            // rather than the next request inheriting it.
                            //
                            // Reclaim the DI scope first, best-effort on
                            // purpose: `close()` is idempotent and only
                            // errors when the scope was already released, so
                            // nothing leaks. The error response below must
                            // still be framed even if this fails — surfaced
                            // in the stats, not swallowed.
                            match active.close() {
                                ok(_) => {}
                                err(_) => { stats.connection_errors += 1 }
                            }
                            // A contained panic leaves the response
                            // half-written at best, so start clean and
                            // render through the SAME gate and problem+json
                            // shape the returned-err path uses
                            // (write_failure): production shows the generic
                            // detail and trace id, detailed_errors shows the
                            // panic text — never the bare panic message or
                            // its "runtime panic at L:C" source position.
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
                                active.head_only, options, stats)?
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

    // Ends a streamed response.
    //
    // `complete` says whether the handler finished normally. When it did, the
    // terminating chunk goes out and the connection may stay alive; when it
    // did not, the body is deliberately left unterminated and the connection
    // closes — a truncated chunked message is how HTTP says a response is
    // broken, and once the head has gone out it is the only signal left.
    fn end_stream(active: HttpContext,
                  complete: bool,
                  stats: ServerStats) -> Result<bool> {
        match active.claim_stream() {
            none => {
                return err("a streamed request lost its writer", "state")
            }
            some(writer) => {
                var ended: Result<bool> = ok(true)
                if complete {
                    ended = writer.finish()
                } else {
                    self.close_after_write = true
                }
                if !active.request.keep_alive {
                    self.close_after_write = true
                }
                match active.close() {
                    ok(_) => {}
                    err(_) => { stats.connection_errors += 1 }
                }
                ended?
                stats.responses += 1
                stats.streamed += 1
                return ok(true)
            }
        }
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
                    created.arm_serving(self.io)
                    self.context = some(created)
                }
                self.have_head = true
                match self.context {
                    some(active) => {
                        match app.begin_request(active, request) {
                            ok(_) => {
                                // Reserve the body to its declared length so
                                // the pieces that follow fill one allocation
                                // instead of regrowing it — a 101 KB body
                                // through a 64 KB read buffer regrows once
                                // per request otherwise. Bounded by
                                // `max_body` (which the body loop enforces
                                // anyway), so a lying Content-Length can
                                // never reserve more than a real body could;
                                // chunked or bodyless declares -1 and
                                // reserves nothing.
                                let declared: int = request.content_length
                                if declared > 0 && declared <= self.max_body {
                                    active.request.body.reserve(declared)
                                    if declared > options.read_buffer_bytes {
                                        stats.request_bodies_presized += 1
                                    }
                                }
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
                                self.upgrade_pending = request.upgrade
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
                // The upgrade event decides this message's fate; see
                // upgrade_pending.
                if self.upgrade_pending { return ok(true) }
                self.dispatch(app, keep_alive, options, stats)?
                // The response is sent; a body buffer that outgrew one read is
                // no longer needed and must not be carried for the life of the
                // connection.
                match self.context {
                    some(active) => {
                        if active.request.release_large_body(
                                options.read_buffer_bytes) {
                            stats.request_buffers_released += 1
                        }
                    }
                    none => {}
                }
            }
            upgraded(request, remainder) => {
                return self.hand_off_protocol(
                    request, remainder, app, options, stats)
            }
        }
        return ok(true)
    }

    // A client that asked to switch protocols. The parser is finished with
    // this connection either way — whatever follows the head belongs to the
    // next protocol — so every branch below ends the loop.
    //
    // The pipeline runs first, exactly as for an ordinary request: skipping
    // it would skip authentication, the session cookie and the `Origin`
    // check — precisely what a cross-site WebSocket hijack needs skipped.
    // The socket moves only after a layer lets the request through and an
    // upgrade endpoint matched.
    fn hand_off_protocol(head: http.Request,
                         remainder: Bytes,
                         app: WebApplication,
                         options: ServerOptions,
                         stats: ServerStats) -> Result<bool> {
        self.have_head = false
        self.upgrade_pending = false
        self.close_after_write = true
        self.requests += 1
        stats.requests += 1
        match self.context {
            none => {
                return err("an upgrade arrived without a context", "state")
            }
            some(active) => {
                // Bytes after the head are the next protocol's, and this
                // server has not yet decided that there is a next protocol.
                // They cannot be put back and a handler given the socket would
                // start mid-stream, so refuse the handshake rather than hand
                // over a connection whose first frames are already spent.
                if remainder.len() > 0 {
                    match active.close() {
                        ok(_) => {}
                        err(_) => { stats.connection_errors += 1 }
                    }
                    self.append_error(
                        400, "Bad Request",
                        "bytes arrived after the upgrade request, so this connection cannot be handed to another protocol",
                        false, options)?
                    stats.responses += 1
                    return ok(false)
                }
                active.request.keep_alive = false
                match app.handle_upgrade_context(active) {
                    ok(_) => {}
                    err(problem) => {
                        app.record_failure(active, problem.msg)
                        match active.close() {
                            ok(_) => {}
                            err(_) => { stats.connection_errors += 1 }
                        }
                        active.response.reset()
                        app.write_failure(
                            active, problem.msg, problem.kind)?
                        if app.server_header() != "" &&
                           !active.response.headers.has("Server") {
                            active.response.header(
                                "Server", app.server_header())
                        }
                        self.append_response_from(
                            active.response, false, false, options, stats)?
                        stats.responses += 1
                        return ok(false)
                    }
                }
                match active.claim_upgrade() {
                    none => {
                        // A layer answered, or no endpoint speaks this path.
                        let queued: Result<bool> = self.append_response_from(
                            active.response, false, active.head_only,
                            options, stats)
                        let closed: Result<bool> = active.close()
                        queued?
                        closed?
                        stats.responses += 1
                        return ok(false)
                    }
                    some(handler) => {
                        // Pipelined responses framed before this request are
                        // still in the output queue. They go out first: the
                        // next protocol's first bytes must not overtake the
                        // answers to requests that preceded it, and after the
                        // hand-off there is nothing left to send them with.
                        if self.io.has_output() { self.io.flush()? }
                        stats.upgrades += 1
                        let outcome: Result<bool> = shielded_upgrade(
                            handler, active, head, self.io.hand_off())
                        // The request scope outlives the handshake and is
                        // released here, after the handler has finished with
                        // the connection — a socket handler holds services for
                        // as long as it holds the socket.
                        match active.close() {
                            ok(_) => {}
                            err(_) => { stats.connection_errors += 1 }
                        }
                        match outcome {
                            ok(_) => { return ok(false) }
                            err(problem) => {
                                app.record_failure(active, problem.msg)
                                return err(problem.msg, problem.kind)
                            }
                        }
                    }
                }
            }
        }
    }

    fn absorb(app: WebApplication,
              options: ServerOptions,
              stats: ServerStats) -> Result<bool> {
        for position: int in 0..self.events.len() {
            let proceed: bool = self.absorb_event(
                self.events[position], app, options, stats)?
            if !proceed { return ok(false) }
            if self.close_after_write { return ok(false) }
            // One read can carry hundreds of pipelined requests, all framed
            // here before the read loop's flush. Unbounded, the queue grows
            // to the whole batch — 13 KB of pipelined requests can become
            // megabytes of per-connection buffer — so push it once it
            // reaches what this connection is allowed to hold.
            //
            // An event is absorbed whole, so the queue always ends on a
            // response boundary: complete responses, in framed order, and
            // the next cannot be framed until this returns — the same
            // ordering guarantee `flush_with_body` relies on.
            if self.io.output.len() >= self.io.max_queued {
                stats.output_queue_flushes += 1
                self.io.flush()?
            }
        }
        // A head that asked to switch protocols is answered by the `upgraded`
        // event, which the parser emits in the same batch. Reaching the end of
        // a batch with the flag still set means it did not, so the request
        // would sit unanswered until the idle timeout — refuse it here
        // instead, with the reason, and close.
        if self.upgrade_pending {
            self.upgrade_pending = false
            self.requests += 1
            stats.requests += 1
            self.append_error(
                400, "Bad Request",
                "the request asked to switch protocols but the parser handed over no connection",
                false, options)?
            stats.responses += 1
            self.close_after_write = true
            return ok(false)
        }
        return ok(true)
    }

    // The connection's whole life: read, parse, dispatch, flush, repeat.
    // Returns false when the connection died of a transport error the
    // stats should count, true for every clean ending.
    fn serve(app: WebApplication,
             options: ServerOptions,
             stats: ServerStats) -> bool {
        let armed: Result<bool> = self.io.arm_timeouts(
            options.idle_timeout_ms, options.idle_timeout_ms)
        for !self.close_after_write {
            // wait-first: between requests the socket is drained, so the
            // speculative recv would only say would-block.
            match self.io.read_waiting(self.read_buffer) {
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
                    if self.io.has_output() {
                        match self.io.flush() {
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
        if self.io.has_output() {
            match self.io.flush() {
                ok(_) => {}
                err(problem) => { return false }
            }
        }
        return true
    }

    fn close() -> Result<bool> { return self.io.close() }
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
        new ServerConnection(move stream, peer, options, stats)
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
