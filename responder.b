package espresso

/// One finished deferred response, carried from any thread back to the
/// connection fiber that owns the request. It travels through a one-slot
/// channel created for exactly one request, so there is no request id to
/// match and nothing for a late payload to corrupt: a response that arrives
/// after the pending timeout lands in an orphaned channel and is collected
/// with it.
unique class Completion implements Send {
    status: int
    reason: string
    content_type: string
    header_names: List<string>
    header_values: List<string>
    body: Bytes

    fn init(status: int,
            reason: string,
            content_type: string,
            move header_names: List<string>,
            move header_values: List<string>,
            move body: Bytes) {
        self.status = status
        self.reason = reason
        self.content_type = content_type
        self.header_names = move header_names
        self.header_values = move header_values
        self.body = move body
    }
}

/// The move-only, Send half of one deferred response. A handler obtains it
/// with `context.respond_later()`, moves it wherever the work happens, and
/// finishes the request by calling exactly one sending method. Late or
/// repeated sends are harmless: the one-shot flag refuses a second send, and
/// a payload for a request that timed out sinks into its orphaned channel.
pub unique class Responder implements Send {
    reply: Channel<Completion>
    sent: bool = false
    header_names: List<string> = []
    header_values: List<string> = []

    fn init(reply: Channel<Completion>) {
        self.reply = reply
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
        // The channel holds one slot and this is its only send, so the send
        // never blocks; the waiting connection fiber wakes on its next poll.
        self.reply.send(new Completion(
            status, reason, content_type,
            move names, move values, move body))
        return ok(true)
    }
}
