package espresso

import std.poll

// One finished deferred response, carried from any thread back to the event
// loop that owns the connection. `token` and `generation` name the exact
// request the payload answers; a stale pair makes the payload a no-op.
struct Completion {
    token: int
    generation: int
    status: int
    reason: string
    content_type: string
    header_names: List<string>
    header_values: List<string>
    body: Bytes
}

// Where deferred responses land: the owning loop's completion queue plus the
// wake handle that tells its poller to drain. Copyable and Send, so a
// Responder can carry it into a worker thread.
struct LoopMailbox {
    completions: Mutex<List<Completion>>
    signal: int
}

/// The move-only, Send half of one deferred response. A handler obtains it
/// with `context.respond_later()`, moves it wherever the work happens, and
/// finishes the request by calling exactly one sending method. Late or
/// repeated sends are harmless: the loop drops any payload whose request is
/// already answered or whose connection is gone.
pub unique class Responder implements Send {
    mailbox: LoopMailbox
    token: int
    generation: int
    sent: bool = false
    header_names: List<string> = []
    header_values: List<string> = []

    fn init(mailbox: LoopMailbox, token: int, generation: int) {
        self.mailbox = mailbox
        self.token = token
        self.generation = generation
    }

    /// Adds a header to the eventual response. Content-Length and Connection
    /// stay with the server.
    pub fn header(name: string, value: string) {
        self.header_names.push(name)
        self.header_values.push(value)
    }

    /// Sends a response with the given body bytes.
    pub fn bytes(status: int, reason: string, move body: Bytes,
                 content_type: string = "application/octet-stream") -> Result<bool> {
        return self.deliver(status, reason, move body, content_type)
    }

    /// Sends a plain-text response.
    pub fn text(status: int, reason: string, body: string) -> Result<bool> {
        return self.deliver(status, reason, Bytes.from(body),
                            "text/plain; charset=utf-8")
    }

    /// Sends an already-encoded JSON response.
    pub fn json(status: int, reason: string, encoded: string) -> Result<bool> {
        return self.deliver(status, reason, Bytes.from(encoded),
                            "application/json; charset=utf-8")
    }

    fn deliver(status: int, reason: string, move body: Bytes,
               content_type: string) -> Result<bool> {
        if self.sent {
            return err("this responder already sent its response", "responder")
        }
        self.sent = true
        // Headers are copied out because a move capture cannot be moved out
        // of `self` again; the lists are tiny.
        var names: List<string> = []
        var values: List<string> = []
        for index: int in 0..self.header_names.len() {
            names.push(self.header_names[index])
            values.push(self.header_values[index])
        }
        var carrier: List<Completion> = []
        carrier.push(Completion {
            token: self.token,
            generation: self.generation,
            status: status,
            reason: reason,
            content_type: content_type,
            header_names: move names,
            header_values: move values,
            body: move body,
        })
        self.mailbox.completions.with_lock(fn(waiting: List<Completion>) {
            let next: Option<Completion> = carrier.pop()
            if !next.is_none() {
                waiting.push((move next).expect("completion"))
            }
        })
        return poll.wake(self.mailbox.signal)
    }
}
