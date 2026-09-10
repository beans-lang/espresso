// Streamed responses: the head goes out before the body exists, and the
// body is written as chunks.
//
// The buffered path stays the default: a handler that returns an
// `ActionResult` never touches this. This second mode is for a response
// whose length is not known when the head must go out — a page rendered in
// pieces, a report generated as it is written, a feed that never ends.
package espresso

import std.http

// A chunk's size is hex, per RFC 9112 §7.1. Lower case, no leading zeros,
// which is what every server writes and every client reads.
fn append_hex(target: Bytes, value: int) {
    if value == 0 {
        target.push(48)
        return
    }
    let digits: Bytes = new Bytes(0)
    var left: int = value
    for left > 0 {
        let nibble: int = left % 16
        digits.push(if nibble < 10 { 48 + nibble } else { 87 + nibble })
        left = left / 16
    }
    var index: int = digits.len()
    for index > 0 {
        index -= 1
        target.push(digits.get(index))
    }
}

/// The writer `context.begin_stream()` returns: one chunk per `write`, and a
/// terminator when the response ends.
///
/// The payload is never copied. A chunk is one vectored write of its size
/// line and the caller's own bytes; the CRLF that closes a chunk rides the
/// front of the next chunk's size line, so a chunk costs exactly one write
/// whatever its size — a megabyte written here is a megabyte read straight
/// out of the caller's buffer.
///
/// Backpressure parks the connection fiber inside that write, through the
/// same loop a buffered flush uses: a slow client costs one parked fiber and
/// nothing else on the worker.
pub class ResponseStream {
    io: ConnectionIo
    // A HEAD response carries the head of the GET response and no body at
    // all (RFC 9110 §9.3.2), so every chunk is dropped and no terminator is
    // written — the head already said `Transfer-Encoding: chunked` and that
    // is what a HEAD is supposed to report.
    head_only: bool
    // Holds a chunk's size line, and nothing else. It is reused for every
    // chunk, so a stream of any length allocates it once.
    scratch: Bytes = new Bytes(0)
    // A chunk ends with CRLF. Writing it at the front of the next chunk's
    // size line — instead of as a write of its own — is what keeps a chunk to
    // one syscall without copying the payload.
    pending_crlf: bool = false
    finished: bool = false
    chunks: int = 0
    payload_bytes: int = 0

    fn init(io: ConnectionIo, head_only: bool) {
        self.io = io
        self.head_only = head_only
        self.scratch.reserve(32)
    }

    /// Sends one chunk.
    ///
    /// An empty payload is **refused**, not skipped: `0\r\n\r\n` is the
    /// terminator, so a zero-length chunk written into the middle of a body
    /// ends the response there and everything after it is read as trailers —
    /// silently, with a 200 already on the wire. A caller with nothing to send
    /// must send nothing, and this says so at the call rather than truncating
    /// the page.
    pub fn write(data: Bytes) -> Result<bool> {
        if self.finished {
            return err("this streamed response is already finished", "stream")
        }
        if data.len() == 0 {
            return err(
                "a streamed chunk cannot be empty: a zero-length chunk is the terminator, so writing one would end the response here",
                "stream")
        }
        if self.head_only { return ok(true) }
        self.open_chunk(data.len())
        self.io.push_pair(self.scratch, data)?
        self.chunks += 1
        self.payload_bytes += data.len()
        self.pending_crlf = true
        return ok(true)
    }

    /// The string twin of `write`. The string's own bytes go on the wire; it
    /// is never staged in a buffer first, and an empty one is refused for the
    /// reason `write` gives.
    pub fn write_text(text: string) -> Result<bool> {
        if self.finished {
            return err("this streamed response is already finished", "stream")
        }
        if text.len() == 0 {
            return err(
                "a streamed chunk cannot be empty: a zero-length chunk is the terminator, so writing one would end the response here",
                "stream")
        }
        if self.head_only { return ok(true) }
        self.open_chunk(text.len())
        self.io.push_pair_text(self.scratch, text)?
        self.chunks += 1
        self.payload_bytes += text.len()
        self.pending_crlf = true
        return ok(true)
    }

    // The bytes in front of a chunk's payload: the CRLF owed by the previous
    // chunk, then this one's size line.
    fn open_chunk(length: int) {
        self.scratch.resize(0)
        if self.pending_crlf { self.scratch.append_string("\r\n") }
        append_hex(self.scratch, length)
        self.scratch.append_string("\r\n")
    }

    /// Ends the response with the terminating chunk. Calling it again does
    /// nothing, and the connection calls it for a handler that returned
    /// without doing so — a response that stopped mid-body would otherwise
    /// look complete to nobody and hang the client until it timed out.
    pub fn finish() -> Result<bool> {
        if self.finished { return ok(true) }
        self.finished = true
        if self.head_only { return ok(true) }
        self.scratch.resize(0)
        if self.pending_crlf { self.scratch.append_string("\r\n") }
        self.scratch.append_string("0\r\n\r\n")
        return self.io.push_all(self.scratch)
    }

    /// How many chunks this response has sent.
    pub fn chunk_count() -> int { return self.chunks }

    /// How many payload bytes this response has sent, not counting framing.
    pub fn byte_count() -> int { return self.payload_bytes }

    /// True once the terminating chunk has been written.
    pub fn is_finished() -> bool { return self.finished }
}

// Frames a streamed response's head into `target`.
//
// `encode_response_head_append` cannot write this head itself — it always
// emits a Content-Length and refuses a caller-supplied Transfer-Encoding
// outright (`respond owns HTTP framing`) — but it is still what validates
// the head, on a scratch buffer whose bytes are thrown away: status range,
// reason phrase, every header name as a token, every value free of CR, LF
// and NUL, and the refusal of a caller-supplied Content-Length,
// Transfer-Encoding or Connection. That keeps one copy of those rules in
// std.http, so a rule tightened there tightens here too.
//
// It also reports which statuses forbid a body — exactly the set that
// cannot be streamed.
fn write_stream_head(target: Bytes,
                     status: int,
                     reason: string,
                     headers: http.Headers,
                     keep_alive: bool) -> Result<bool> {
    let probe: Bytes = new Bytes(0)
    let body_forbidden: bool = http.encode_response_head_append(
        probe, status, reason, headers, 0, keep_alive)?
    if body_forbidden {
        return err(
            "status {status} cannot carry a response body, so it cannot be streamed",
            "stream")
    }
    target.append_string("HTTP/1.1 ")
    target.append_int_text(status)
    target.push(32)
    target.append_string(reason)
    target.append_string("\r\n")
    target.append_string("Transfer-Encoding: chunked\r\n")
    if !keep_alive { target.append_string("Connection: close\r\n") }
    for index: int in 0..headers.count() {
        target.append_string(headers.name_at(index))
        target.append_string(": ")
        target.append_string(headers.value_at(index))
        target.append_string("\r\n")
    }
    target.append_string("\r\n")
    return ok(true)
}
