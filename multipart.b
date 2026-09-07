// multipart/form-data: a push parser, per-part sinks, and the limits that
// make an upload endpoint safe to expose.
//
// The parser is fed the way std.http's is — push bytes, take events — because
// a boundary lands across a read as often as not, and a parser that can only
// see a whole body has no answer for that. Every state it can be left in
// between feeds is a state it can resume from, which is what the byte-split
// property in tests/multipart.b measures: however the same bytes are cut up,
// the same parts come out.
//
// Two rules run through the whole file. **The client's Content-Type is never
// trusted**: an allowed-type list can refuse a part, never authorize one, and
// nothing downstream learns what a file is from what the client called it.
// **The submitted filename is metadata, never a path**: stored bytes are named
// by an id this package generates, and there is deliberately no helper that
// turns a submitted name into a path, because that helper is the bug.
package espresso

import std.http
import std.random

// ---- limits ------------------------------------------------------------------

/// What a multipart body may cost. Every one of these has a refusal that names
/// what was crossed, because "413" with no reason is a support ticket.
pub class MultipartLimits {
    /// How many parts a body may carry.
    pub max_parts: int = 64
    /// The largest payload one part may carry.
    pub max_part_bytes: int = 4194304
    /// The largest total payload, across every part.
    pub max_total_bytes: int = 8388608
    /// The longest submitted filename that will be kept as metadata.
    pub max_filename_bytes: int = 255
    /// The longest form field name a part may claim.
    pub max_field_name_bytes: int = 128
    /// The largest header block one part may carry.
    pub max_part_header_bytes: int = 8192
    /// How many header fields one part may carry.
    pub max_part_headers: int = 32
    /// How much whitespace may follow a boundary before its line ends. RFC
    /// 2046 permits transport padding there.
    ///
    /// It is not a refusal: more whitespace than this simply means the bytes
    /// were not a delimiter after all, and they are handed to the part as
    /// body. What it bounds is how far ahead the parser must look before it
    /// can decide, and therefore how much it may hold undecided.
    pub max_boundary_padding_bytes: int = 64
    /// Media types a **file** part may declare. Empty allows every one.
    ///
    /// A non-empty list can only refuse, never authorize: a part that names an
    /// allowed type is still not believed to be that type, and nothing in this
    /// package decides what a file is from what the client called it. It is
    /// there so an endpoint that only ever wants images can say no early,
    /// before a byte of the part is stored.
    pub allowed_file_types: List<string> = []

    pub fn init() {}

    fn allows_type(declared: string) -> bool {
        if self.allowed_file_types.len() == 0 { return true }
        for allowed: string in self.allowed_file_types {
            if media_type_is(declared, allowed) { return true }
        }
        return false
    }
}

// ---- what a part says about itself --------------------------------------------

/// One part's head: what the client said about it, none of it trusted.
pub class PartInfo {
    /// The form field name, from `Content-Disposition: form-data; name="…"`.
    pub name: string = ""
    /// The submitted filename, **metadata only**. It is never used as a path
    /// and never used to name stored bytes.
    pub filename: string = ""
    /// True when the part carried a `filename` parameter at all, which is how
    /// RFC 7578 distinguishes a file from a scalar field — an empty filename
    /// is still a file.
    pub is_file: bool = false
    /// The media type the client declared, or "". Not trusted.
    pub declared_type: string = ""
    /// Every header the part carried.
    pub headers: http.Headers = new http.Headers()

    pub fn init() {}
}

/// What `feed_into` hands back, in order: `part_head`, any number of
/// `part_body` pieces, `part_done`, repeating, then exactly one `finished`.
///
/// How the body divides into `part_body` events depends on how the bytes
/// arrived; what those events concatenate to does not.
pub enum PartEvent {
    part_head(part: PartInfo)
    part_body(data: Bytes)
    part_done(size: int)
    finished(parts: int)
}

// ---- the boundary ---------------------------------------------------------------

// A header parameter list — `form-data; name="a"; filename="b;c"` — read with
// quotes respected, because a filename may legitimately contain a semicolon
// and splitting on it first is how that name gets truncated.
fn header_parameter(value: string, wanted: string) -> Option<string> {
    var index: int = 0
    // Skip the leading token (`form-data`, `multipart/form-data`).
    for index < value.len() && value.byte_at(index) != 59 { index += 1 }
    for index < value.len() {
        index += 1
        for index < value.len() {
            let byte: int = value.byte_at(index)
            if byte != 32 && byte != 9 { break }
            index += 1
        }
        var name_end: int = index
        for name_end < value.len() {
            let byte: int = value.byte_at(name_end)
            if byte == 61 || byte == 59 { break }
            name_end += 1
        }
        let key: string = value.slice(index, name_end).to_lower()
        if name_end >= value.len() || value.byte_at(name_end) == 59 {
            index = name_end
            if key == wanted { return some("") }
            continue
        }
        var at: int = name_end + 1
        var found: string = ""
        if at < value.len() && value.byte_at(at) == 34 {
            at += 1
            var built: string = ""
            for at < value.len() {
                let byte: int = value.byte_at(at)
                if byte == 92 && at + 1 < value.len() {
                    built = "{built}{value.slice(at + 1, at + 2)}"
                    at += 2
                    continue
                }
                if byte == 34 { break }
                built = "{built}{value.slice(at, at + 1)}"
                at += 1
            }
            found = built
            if at < value.len() { at += 1 }
        } else {
            var end: int = at
            for end < value.len() && value.byte_at(end) != 59 { end += 1 }
            found = value.slice(at, end).trim()
            at = end
        }
        if key == wanted { return some(found) }
        index = at
    }
    return none
}

/// The boundary from a `multipart/form-data` Content-Type, or an error saying
/// why this body is not one.
pub fn multipart_boundary(content_type: string) -> Result<string> {
    if !media_type_is(content_type, "multipart/form-data") {
        return err(
            "this endpoint reads a multipart/form-data body, not '{content_type}'",
            "unsupported_media_type")
    }
    match header_parameter(content_type, "boundary") {
        none => {
            return err("the multipart Content-Type carries no boundary",
                       "bad_request")
        }
        some(boundary) => {
            // RFC 2046 §5.1.1: 1 to 70 characters, none of them a control
            // byte, and not ending in a space.
            if boundary.len() == 0 || boundary.len() > 70 {
                return err(
                    "a multipart boundary must be 1 to 70 characters, not {boundary.len()}",
                    "bad_request")
            }
            for index: int in 0..boundary.len() {
                let byte: int = boundary.byte_at(index)
                if byte < 32 || byte == 127 {
                    return err(
                        "the multipart boundary carries a control byte",
                        "bad_request")
                }
            }
            return ok(boundary)
        }
    }
}

// ---- the push parser ------------------------------------------------------------

// Parser states.
fn st_body() -> int { return 0 }
fn st_headers() -> int { return 1 }
fn st_epilogue() -> int { return 2 }
fn st_failed() -> int { return 3 }

// What follows a matched delimiter.
fn tail_need_more() -> int { return 0 }
fn tail_next_part() -> int { return 1 }
fn tail_closing() -> int { return 2 }
// The bytes matched the delimiter but what follows is neither a line end nor
// a closing `--`, so they were never a delimiter: `\r\n--boundaryX` inside a
// payload is payload, and a parser that called it malformed would refuse
// bodies that are perfectly legal.
fn tail_not_a_delimiter() -> int { return 3 }

/// Parses a multipart body from bytes pushed at it in any pieces.
///
/// `feed_into` appends events for everything the bytes decided and keeps what
/// they did not. `finish_into` says whether the body ended where it should
/// have. The parser holds at most one delimiter's worth of undecided bytes
/// plus the piece it was last fed, so a 4 GB upload costs no more memory than
/// a 4 KB one.
pub class MultipartParser {
    // "\r\n--" + boundary. Every part after the first is preceded by it, and
    // the first is too once `pending` is primed with a CRLF that the body did
    // not send — which is what makes the opening delimiter and every later one
    // the same search.
    delimiter: string
    limits: MultipartLimits
    pending: Bytes = new Bytes(0)
    state: int = 0
    in_part: bool = false
    parts: int = 0
    part_bytes: int = 0
    total_bytes: int = 0
    // How many bytes the padding-and-line-end after a matched delimiter
    // occupies, written by classify_tail and read by the one caller.
    tail_width: int = 0
    complete: bool = false

    fn init(boundary: string, limits: MultipartLimits) {
        self.delimiter = "\r\n--{boundary}"
        self.limits = limits
        self.pending.append_string("\r\n")
    }

    /// Builds a parser for `boundary`.
    pub static fn with_boundary(boundary: string,
                                limits: MultipartLimits) ->
        Result<MultipartParser> {
        if boundary.len() == 0 {
            return err("a multipart parser needs a boundary", "bad_request")
        }
        return ok(new MultipartParser(boundary, limits))
    }

    /// Builds a parser from a request's Content-Type.
    pub static fn for_content_type(content_type: string,
                                   limits: MultipartLimits) ->
        Result<MultipartParser> {
        return MultipartParser.with_boundary(
            multipart_boundary(content_type)?, limits)
    }

    /// True once the closing delimiter has been seen.
    pub fn is_finished() -> bool { return self.complete }

    fn fail(message: string, kind: string) -> Result<bool> {
        self.state = st_failed()
        return err(message, kind)
    }

    fn drop_front(count: int) {
        self.pending = self.pending.slice(count, self.pending.len())
    }

    // Hands `count` bytes of the current part to the caller, counting them
    // against the per-part and whole-body limits first.
    fn emit_body(count: int, out: List<PartEvent>) -> Result<bool> {
        if count <= 0 { return ok(true) }
        if !self.in_part {
            // Preamble. RFC 2046 says to ignore it; it is not a part and it is
            // not counted against a part's budget.
            self.drop_front(count)
            return ok(true)
        }
        if self.part_bytes + count > self.limits.max_part_bytes {
            return self.fail(
                "a multipart part exceeds the {self.limits.max_part_bytes}-byte limit",
                "payload_too_large")
        }
        if self.total_bytes + count > self.limits.max_total_bytes {
            return self.fail(
                "the multipart body exceeds the {self.limits.max_total_bytes}-byte total limit",
                "payload_too_large")
        }
        self.part_bytes += count
        self.total_bytes += count
        out.push(PartEvent.part_body(self.pending.slice(0, count)))
        self.drop_front(count)
        return ok(true)
    }

    fn read_headers(block: string, out: List<PartEvent>) -> Result<bool> {
        let part: PartInfo = new PartInfo()
        var count: int = 0
        if block != "" {
            for line: string in block.split("\r\n") {
                if line == "" { continue }
                count += 1
                if count > self.limits.max_part_headers {
                    return self.fail(
                        "a multipart part carries more than {self.limits.max_part_headers} headers",
                        "payload_too_large")
                }
                match line.find(":") {
                    none => {
                        return self.fail(
                            "a multipart part header has no colon", "bad_request")
                    }
                    some(at) => {
                        let name: string = line.slice(0, at).trim()
                        let value: string =
                            line.slice(at + 1, line.len()).trim()
                        if name == "" {
                            return self.fail(
                                "a multipart part header has an empty name",
                                "bad_request")
                        }
                        part.headers.add(name, value)
                    }
                }
            }
        }
        let disposition: string =
            part.headers.get("Content-Disposition").or("")
        if disposition == "" {
            return self.fail(
                "a multipart part carries no Content-Disposition",
                "bad_request")
        }
        match header_parameter(disposition, "name") {
            none => {
                return self.fail(
                    "a multipart part carries no field name", "bad_request")
            }
            some(name) => {
                if name.len() > self.limits.max_field_name_bytes {
                    return self.fail(
                        "a multipart field name is longer than {self.limits.max_field_name_bytes} bytes",
                        "payload_too_large")
                }
                if name.contains("\u{0}") {
                    return self.fail(
                        "a multipart field name contains a NUL byte",
                        "bad_request")
                }
                part.name = name
            }
        }
        match header_parameter(disposition, "filename") {
            none => {}
            some(filename) => {
                if filename.len() > self.limits.max_filename_bytes {
                    return self.fail(
                        "a submitted filename is longer than {self.limits.max_filename_bytes} bytes",
                        "payload_too_large")
                }
                if filename.contains("\u{0}") {
                    return self.fail(
                        "a submitted filename contains a NUL byte",
                        "bad_request")
                }
                part.is_file = true
                part.filename = filename
            }
        }
        part.declared_type = part.headers.get("Content-Type").or("")
        if part.is_file && !self.limits.allows_type(part.declared_type) {
            return self.fail(
                "a file part declares '{part.declared_type}', which this endpoint does not accept",
                "unsupported_media_type")
        }
        self.parts += 1
        if self.parts > self.limits.max_parts {
            return self.fail(
                "the multipart body carries more than {self.limits.max_parts} parts",
                "payload_too_large")
        }
        self.part_bytes = 0
        self.in_part = true
        out.push(PartEvent.part_head(part))
        return ok(true)
    }

    // Classifies what follows a delimiter matched at `after`, and how many
    // bytes it occupies. The count is written into `self.tail_width`.
    fn classify_tail(after: int) -> int {
        var at: int = after
        for at < self.pending.len() {
            let byte: int = self.pending.get(at)
            if byte != 32 && byte != 9 { break }
            if at - after >= self.limits.max_boundary_padding_bytes {
                self.tail_width = 0
                return tail_not_a_delimiter()
            }
            at += 1
        }
        if at + 2 > self.pending.len() {
            self.tail_width = 0
            return tail_need_more()
        }
        let first: int = self.pending.get(at)
        let second: int = self.pending.get(at + 1)
        self.tail_width = at + 2 - after
        if first == 45 && second == 45 { return tail_closing() }
        if first == 13 && second == 10 { return tail_next_part() }
        self.tail_width = 0
        return tail_not_a_delimiter()
    }

    // Runs until the bytes on hand decide nothing more.
    fn advance(out: List<PartEvent>) -> Result<bool> {
        for {
            if self.state == st_failed() {
                return err("this multipart parser already failed", "closed")
            }
            if self.state == st_epilogue() {
                // Everything after the closing delimiter is discarded.
                self.pending = new Bytes(0)
                return ok(true)
            }
            if self.state == st_body() {
                let hit: int = find_bytes(self.pending, self.delimiter, 0)
                if hit < 0 {
                    // No whole delimiter here. One may still straddle the end
                    // of what has arrived, so the last
                    // delimiter-length-minus-one bytes stay undecided — a
                    // delimiter cannot start inside itself, because its first
                    // four bytes are CRLF-- and a boundary may hold no control
                    // byte.
                    let keep: int = self.delimiter.len() - 1
                    if self.pending.len() > keep {
                        self.emit_body(self.pending.len() - keep, out)?
                    }
                    return ok(true)
                }
                let verdict: int = self.classify_tail(
                    hit + self.delimiter.len())
                if verdict == tail_need_more() {
                    // Hand over everything in front of it and wait for the
                    // bytes that decide what it is.
                    self.emit_body(hit, out)?
                    return ok(true)
                }
                if verdict == tail_not_a_delimiter() {
                    // Payload that merely looks like a delimiter. Hand it over
                    // whole and keep scanning behind it.
                    self.emit_body(hit + self.delimiter.len(), out)?
                    continue
                }
                self.emit_body(hit, out)?
                self.drop_front(self.delimiter.len() + self.tail_width)
                if self.in_part {
                    out.push(PartEvent.part_done(self.part_bytes))
                    self.in_part = false
                }
                if verdict == tail_closing() {
                    self.complete = true
                    self.state = st_epilogue()
                    out.push(PartEvent.finished(self.parts))
                    continue
                }
                self.state = st_headers()
                continue
            }
            // st_headers
            let end: int = find_bytes(self.pending, "\r\n\r\n", 0)
            if end < 0 {
                if self.pending.len() > self.limits.max_part_header_bytes {
                    return self.fail(
                        "a multipart part's headers exceed {self.limits.max_part_header_bytes} bytes",
                        "payload_too_large")
                }
                return ok(true)
            }
            if end > self.limits.max_part_header_bytes {
                return self.fail(
                    "a multipart part's headers exceed {self.limits.max_part_header_bytes} bytes",
                    "payload_too_large")
            }
            let block: string = self.pending.slice(0, end).to_string()
            self.drop_front(end + 4)
            self.read_headers(block, out)?
            self.state = st_body()
        }
        return ok(true)
    }

    /// Pushes `data[from..to]` and appends whatever it decided to `out`.
    pub fn feed_into(data: Bytes, from: int, to: int,
                     out: List<PartEvent>) -> Result<bool> {
        if from < 0 || to > data.len() || from > to {
            return err("the multipart feed range is out of bounds", "invalid")
        }
        if self.state == st_failed() {
            return err("this multipart parser already failed", "closed")
        }
        if from != to { self.pending.append(data.slice(from, to)) }
        return self.advance(out)
    }

    /// Pushes a whole buffer.
    pub fn feed(data: Bytes, out: List<PartEvent>) -> Result<bool> {
        return self.feed_into(data, 0, data.len(), out)
    }

    /// Ends the body. A body that stopped before its closing delimiter is an
    /// error: the last part is truncated and there is no way to know by how
    /// much.
    pub fn finish_into(out: List<PartEvent>) -> Result<bool> {
        if self.state == st_failed() {
            return err("this multipart parser already failed", "closed")
        }
        if !self.complete {
            return self.fail(
                "the multipart body ended before its closing boundary",
                "bad_request")
        }
        return ok(true)
    }
}

// ---- where a part's bytes go -----------------------------------------------------

/// Where one part's bytes go. One sink per part.
///
/// `write` is called for each piece in order, then exactly one of `finish` or
/// `discard`. `finish` answers with the bytes to keep on the part's record,
/// which a sink that wrote them somewhere else — a file, a hash, a socket —
/// leaves empty; `size` on the record is authoritative either way.
pub interface PartSink {
    fn write(data: Bytes) -> Result<bool>
    fn finish() -> Result<Bytes>
    fn discard()
}

/// Chooses a sink for each part. It is given the part's head and the storage
/// id this package generated for it — never the submitted filename, because
/// that name is the client's and a store that builds a path from it is the
/// bug this argument exists to prevent.
pub interface PartStore {
    fn open(part: PartInfo, storage_id: string) -> Result<PartSink>
}

/// A sink that keeps the part in memory.
pub class MemorySink implements PartSink {
    slot: List<Bytes> = []

    pub fn init() { self.slot.push(new Bytes(0)) }

    pub fn write(data: Bytes) -> Result<bool> {
        if self.slot.len() == 0 {
            return err("this sink is already finished", "state")
        }
        self.slot[0].append(data)
        return ok(true)
    }

    pub fn finish() -> Result<Bytes> {
        if self.slot.len() == 0 {
            return err("this sink is already finished", "state")
        }
        return ok(self.slot.remove(0))
    }

    pub fn discard() {
        if self.slot.len() != 0 {
            let dropped: Bytes = self.slot.remove(0)
        }
    }
}

/// The default store: every part is kept in memory, inside the limits the
/// reader was given.
pub class MemoryPartStore implements PartStore {
    pub fn init() {}

    pub fn open(part: PartInfo, storage_id: string) -> Result<PartSink> {
        return ok(new MemorySink())
    }
}

// ---- the collected form ------------------------------------------------------------

/// One file part, after it has been read.
pub class UploadedFile {
    /// The name this package generated for the part's bytes. 32 hex
    /// characters from `std.random`, and the only name anything should use to
    /// refer to them.
    pub storage_id: string
    /// The form field this part came from.
    pub field: string
    /// The filename the client submitted. **Metadata.** It is not where the
    /// bytes are, it is not safe to use as a path, and nothing here makes one
    /// out of it — display it escaped, store it beside the bytes, and address
    /// the bytes by `storage_id`.
    pub submitted_filename: string
    /// What the client called the content. Not trusted, and not what anything
    /// downstream should decide a type from.
    pub declared_type: string
    /// The part's size in bytes, whatever store held it.
    pub size: int
    payload: Bytes

    fn init(storage_id: string, field: string, submitted_filename: string,
            declared_type: string, size: int, move payload: Bytes) {
        self.storage_id = storage_id
        self.field = field
        self.submitted_filename = submitted_filename
        self.declared_type = declared_type
        self.size = size
        self.payload = move payload
    }

    /// The kept bytes as text. Empty when the store wrote them elsewhere.
    pub fn text() -> string { return self.payload.to_string() }

    /// A copy of the kept bytes. Empty when the store wrote them elsewhere.
    pub fn copy_bytes() -> Bytes {
        return self.payload.slice(0, self.payload.len())
    }
}

/// A read multipart body: its scalar fields, and its files.
pub class MultipartForm {
    /// Scalar parts — those with no `filename` — in arrival order, repeated
    /// names kept repeated, exactly like a query string or a urlencoded body.
    pub fields: QueryValues = new QueryValues()
    /// File parts in arrival order.
    pub files: List<UploadedFile> = []

    pub fn init() {}

    /// The first file submitted under `field`, or `none`.
    pub fn file(field: string) -> Option<UploadedFile> {
        for candidate: UploadedFile in self.files {
            if candidate.field == field { return some(candidate) }
        }
        return none
    }

    /// Every file submitted under `field`, in order.
    pub fn files_for(field: string) -> List<UploadedFile> {
        var found: List<UploadedFile> = []
        for candidate: UploadedFile in self.files {
            if candidate.field == field { found.push(candidate) }
        }
        return move found
    }
}

// 32 hex characters from the CSPRNG. It names stored bytes, so it must not be
// guessable and it must not be derived from anything the client sent.
fn storage_id() -> Result<string> {
    let raw: Bytes = random.bytes(16)?
    var out: string = ""
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        let high: int = byte / 16
        let low: int = byte % 16
        let digits: string = "0123456789abcdef"
        out = "{out}{digits.slice(high, high + 1)}{digits.slice(low, low + 1)}"
    }
    return ok(out)
}

/// Reads a whole multipart body into fields and files, sending each part's
/// bytes to a sink the store chooses.
///
/// A scalar part is kept as text whatever the store says, because a form field
/// is small by definition and the caller asked for its value. A file part goes
/// to the store.
pub fn read_multipart_with(request: HttpRequest,
                           limits: MultipartLimits,
                           store: PartStore) -> Result<MultipartForm> {
    let parser: MultipartParser = MultipartParser.for_content_type(
        request.headers.get("Content-Type").or(""), limits)?
    var events: List<PartEvent> = []
    parser.feed(request.body, events)?
    parser.finish_into(events)?
    return collect_multipart(events, store)
}

/// Reads a whole multipart body, keeping every part in memory.
pub fn read_multipart(request: HttpRequest,
                      limits: MultipartLimits) -> Result<MultipartForm> {
    return read_multipart_with(request, limits, new MemoryPartStore())
}

/// Folds a parser's events into a form, opening one sink per part.
///
/// A sink that was opened is always closed: `finish` on the part's last event,
/// `discard` on any failure between, so a store that took a resource for a
/// part never keeps it because the part after it was malformed.
pub fn collect_multipart(events: List<PartEvent>,
                         store: PartStore) -> Result<MultipartForm> {
    let form: MultipartForm = new MultipartForm()
    var open_sinks: List<PartSink> = []
    var heads: List<PartInfo> = []
    var ids: List<string> = []
    var scalar: Bytes = new Bytes(0)
    for event: PartEvent in events {
        match event {
            part_head(part) => {
                var id: string = ""
                match storage_id() {
                    ok(made) => { id = made }
                    err(problem) => {
                        discard_all(open_sinks)
                        return err(problem.msg, problem.kind)
                    }
                }
                scalar = new Bytes(0)
                if part.is_file {
                    match store.open(part, id) {
                        ok(sink) => { open_sinks.push(sink) }
                        err(problem) => {
                            discard_all(open_sinks)
                            return err(problem.msg, problem.kind)
                        }
                    }
                }
                heads.push(part)
                ids.push(id)
            }
            part_body(data) => {
                if heads.len() == 0 {
                    discard_all(open_sinks)
                    return err("a multipart body arrived before its head",
                               "bad_request")
                }
                if heads[heads.len() - 1].is_file {
                    match open_sinks[open_sinks.len() - 1].write(data) {
                        ok(_) => {}
                        err(problem) => {
                            discard_all(open_sinks)
                            return err(problem.msg, problem.kind)
                        }
                    }
                } else {
                    scalar.append(data)
                }
            }
            part_done(size) => {
                if heads.len() == 0 {
                    discard_all(open_sinks)
                    return err("a multipart part ended before it began",
                               "bad_request")
                }
                let head: PartInfo = heads[heads.len() - 1]
                let id: string = ids[ids.len() - 1]
                if head.is_file {
                    let sink: PartSink =
                        open_sinks.remove(open_sinks.len() - 1)
                    var kept: Result<Bytes> = sink.finish()
                    match kept {
                        ok(_) => {}
                        err(problem) => {
                            discard_all(open_sinks)
                            return err(problem.msg, problem.kind)
                        }
                    }
                    form.files.push(new UploadedFile(
                        id, head.name, head.filename, head.declared_type,
                        size, (move kept).expect("part bytes")))
                } else {
                    form.fields.add(head.name, scalar.to_string())
                    scalar = new Bytes(0)
                }
            }
            finished(parts) => {}
        }
    }
    discard_all(open_sinks)
    return ok(move form)
}

fn discard_all(sinks: List<PartSink>) {
    for sink: PartSink in sinks { sink.discard() }
    sinks.clear()
}
