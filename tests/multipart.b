// multipart/form-data: the byte-split property, every body shape the grammar
// allows, every limit, and the per-part sink.
package main

import espresso
import std.http
import std.io

fn crlf() -> string { return "\r\n" }

// A golden file may hold no raw CR — git rewrites it on checkout and the gate
// then fails on a fresh clone — so payloads are shown with their control
// bytes spelled out.
fn visible(value: string) -> string {
    var out: string = ""
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte < 32 || byte == 127 {
            out = "{out}<{byte}>"
        } else {
            out = "{out}{value.slice(index, index + 1)}"
        }
    }
    return out
}

// The events, normalised: the heads, each part's payload concatenated, the
// sizes, the end. How the payload divides into events depends on how the
// bytes arrived; what it concatenates to must not, and that is the property.
fn render(events: List<espresso.PartEvent>) -> string {
    var out: string = ""
    var body: string = ""
    for event: espresso.PartEvent in events {
        match event {
            part_head(part) => {
                out = "{out}head[name={part.name} file={part.is_file} filename={visible(part.filename)} type={part.declared_type} headers={part.headers.count()}] "
                body = ""
            }
            part_body(data) => { body = "{body}{data.to_string()}" }
            part_done(size) => {
                out = "{out}body[{visible(body)}] done[{size}] "
                body = ""
            }
            finished(parts) => { out = "{out}finished[{parts}]" }
        }
    }
    return out
}

// Feeds `body` in pieces of `chunk` bytes (0 means one feed) and returns the
// rendering, or the refusal.
fn parse_chunked(body: string, boundary: string,
                 limits: espresso.MultipartLimits, chunk: int) -> string {
    match espresso.MultipartParser.with_boundary(boundary, limits) {
        err(problem) => { return "open {problem.kind}: {problem.msg}" }
        ok(parser) => {
            let raw: Bytes = Bytes.from(body)
            var events: List<espresso.PartEvent> = []
            var at: int = 0
            let step: int = if chunk <= 0 { raw.len() + 1 } else { chunk }
            for at < raw.len() {
                var end: int = at + step
                if end > raw.len() { end = raw.len() }
                match parser.feed_into(raw, at, end, events) {
                    ok(_) => {}
                    err(problem) => {
                        return "{problem.kind}: {problem.msg}"
                    }
                }
                at = end
            }
            match parser.finish_into(events) {
                ok(_) => {}
                err(problem) => { return "{problem.kind}: {problem.msg}" }
            }
            return render(events)
        }
    }
}

// Feeds `body` as exactly two pieces split at `at`.
fn parse_split(body: string, boundary: string,
               limits: espresso.MultipartLimits, at: int) -> string {
    match espresso.MultipartParser.with_boundary(boundary, limits) {
        err(problem) => { return "open {problem.kind}: {problem.msg}" }
        ok(parser) => {
            let raw: Bytes = Bytes.from(body)
            var events: List<espresso.PartEvent> = []
            match parser.feed_into(raw, 0, at, events) {
                ok(_) => {}
                err(problem) => { return "{problem.kind}: {problem.msg}" }
            }
            match parser.feed_into(raw, at, raw.len(), events) {
                ok(_) => {}
                err(problem) => { return "{problem.kind}: {problem.msg}" }
            }
            match parser.finish_into(events) {
                ok(_) => {}
                err(problem) => { return "{problem.kind}: {problem.msg}" }
            }
            return render(events)
        }
    }
}

// The property: however the same bytes are cut up, the same parts come out.
// Every two-way split, one byte at a time, and a spread of fixed chunk sizes.
fn property(label: string, body: string, boundary: string,
            limits: espresso.MultipartLimits) {
    let whole: string = parse_chunked(body, boundary, limits, 0)
    var splits: int = 0
    var wrong: int = 0
    for at: int in 0..body.len() + 1 {
        splits += 1
        if parse_split(body, boundary, limits, at) != whole { wrong += 1 }
    }
    for chunk: int in [1, 2, 3, 5, 7, 11, 13, 29, 64, 4096] {
        splits += 1
        if parse_chunked(body, boundary, limits, chunk) != whole {
            wrong += 1
        }
    }
    io.println("{label} splits {splits} wrong {wrong}")
    io.println("  {whole}")
}

// ---- the bodies -------------------------------------------------------------

fn field(boundary: string, name: string, value: string) -> string {
    return "--{boundary}{crlf()}Content-Disposition: form-data; name=\"{name}\"{crlf()}{crlf()}{value}{crlf()}"
}

fn file_part(boundary: string, name: string, filename: string,
             kind: string, value: string) -> string {
    return "--{boundary}{crlf()}Content-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"{crlf()}Content-Type: {kind}{crlf()}{crlf()}{value}{crlf()}"
}

fn close(boundary: string) -> string {
    return "--{boundary}--{crlf()}"
}

fn main() {
    let b: string = "----espresso7MA4YWxkTrZu0gW"
    let limits: espresso.MultipartLimits = new espresso.MultipartLimits()

    property("two-fields",
             "{field(b, "a", "1")}{field(b, "b", "2")}{close(b)}", b, limits)

    property("one-file",
             "{field(b, "note", "hello")}{file_part(b, "avatar", "cat.png", "image/png", "PNGDATA")}{close(b)}",
             b, limits)

    // A preamble before the first delimiter and an epilogue after the last:
    // RFC 2046 says both exist and both are ignored.
    property("preamble-epilogue",
             "this is a preamble a client may send{crlf()}{field(b, "a", "1")}{close(b)}and an epilogue",
             b, limits)

    // Payload that looks like a delimiter but is not: `--boundary` with no
    // leading CRLF, and `\r\n--boundary` followed by a letter. A parser that
    // called either one a delimiter would refuse a legal body.
    property("delimiter-lookalike",
             "{field(b, "a", "before--{b}after{crlf()}--{b}X{crlf()}--{b}Xtail")}{close(b)}",
             b, limits)

    // An empty payload, and one that ends with a CRLF of its own — the CRLF
    // in front of a delimiter belongs to the delimiter, not to the payload.
    property("empty-and-crlf",
             "{field(b, "empty", "")}{field(b, "trailing", "line{crlf()}")}{close(b)}",
             b, limits)

    // Transport padding after a delimiter, which RFC 2046 permits.
    property("padded-delimiter",
             "--{b}   {crlf()}Content-Disposition: form-data; name=\"a\"{crlf()}{crlf()}1{crlf()}--{b}--{crlf()}",
             b, limits)

    // A closing delimiter with nothing after it at all.
    property("bare-close",
             "{field(b, "a", "1")}--{b}--", b, limits)

    // A quoted filename holding a semicolon and an escaped quote, and one
    // holding UTF-8. Splitting the parameter list on `;` first truncates the
    // first of these.
    property("awkward-filenames",
             "{file_part(b, "f", "a;b.txt", "text/plain", "one")}--{b}{crlf()}Content-Disposition: form-data; name=\"g\"; filename=\"say \\\"hi\\\".txt\"{crlf()}{crlf()}two{crlf()}{file_part(b, "h", "café.txt", "text/plain", "three")}{close(b)}",
             b, limits)

    // Several headers on one part, and a part with no Content-Type.
    property("many-headers",
             "--{b}{crlf()}Content-Disposition: form-data; name=\"a\"; filename=\"x.bin\"{crlf()}Content-Type: application/octet-stream{crlf()}Content-Transfer-Encoding: binary{crlf()}X-Custom: 1{crlf()}{crlf()}DATA{crlf()}{field(b, "plain", "no type")}{close(b)}",
             b, limits)

    // A one-character boundary: the shortest the grammar allows, and the one
    // most likely to appear inside a payload by accident.
    property("short-boundary",
             "--x{crlf()}Content-Disposition: form-data; name=\"a\"{crlf()}{crlf()}--x is not a delimiter here{crlf()}--x--{crlf()}",
             "x", limits)

    // A payload whose last bytes are a prefix of the delimiter.
    property("delimiter-prefix-tail",
             "{field(b, "a", "tail{crlf()}--{b.slice(0, 8)}")}{close(b)}",
             b, limits)

    // ---- refusals ----------------------------------------------------------

    io.println("-- refusals --")
    let truncated: string = "{field(b, "a", "1")}--{b}{crlf()}Content-Disposition: form-data; name=\"b\"{crlf()}{crlf()}half"
    io.println("truncated {parse_chunked(truncated, b, limits, 0)}")
    io.println("no-disposition {parse_chunked("--{b}{crlf()}Content-Type: text/plain{crlf()}{crlf()}x{crlf()}{close(b)}", b, limits, 0)}")
    io.println("no-name {parse_chunked("--{b}{crlf()}Content-Disposition: form-data{crlf()}{crlf()}x{crlf()}{close(b)}", b, limits, 0)}")
    io.println("no-colon {parse_chunked("--{b}{crlf()}not a header{crlf()}{crlf()}x{crlf()}{close(b)}", b, limits, 0)}")
    io.println("empty-header-name {parse_chunked("--{b}{crlf()}: v{crlf()}{crlf()}x{crlf()}{close(b)}", b, limits, 0)}")

    let few: espresso.MultipartLimits = new espresso.MultipartLimits()
    few.max_parts = 2
    io.println("too-many-parts {parse_chunked("{field(b, "a", "1")}{field(b, "b", "2")}{field(b, "c", "3")}{close(b)}", b, few, 0)}")

    let small: espresso.MultipartLimits = new espresso.MultipartLimits()
    small.max_part_bytes = 4
    io.println("part-too-big {parse_chunked("{field(b, "a", "123456")}{close(b)}", b, small, 0)}")

    let tight: espresso.MultipartLimits = new espresso.MultipartLimits()
    tight.max_total_bytes = 6
    io.println("total-too-big {parse_chunked("{field(b, "a", "1234")}{field(b, "b", "5678")}{close(b)}", b, tight, 0)}")

    let named: espresso.MultipartLimits = new espresso.MultipartLimits()
    named.max_filename_bytes = 4
    io.println("filename-too-long {parse_chunked("{file_part(b, "f", "toolong.txt", "text/plain", "x")}{close(b)}", b, named, 0)}")

    let keyed: espresso.MultipartLimits = new espresso.MultipartLimits()
    keyed.max_field_name_bytes = 2
    io.println("field-name-too-long {parse_chunked("{field(b, "abcdef", "1")}{close(b)}", b, keyed, 0)}")

    let headed: espresso.MultipartLimits = new espresso.MultipartLimits()
    headed.max_part_header_bytes = 20
    io.println("headers-too-big {parse_chunked("{field(b, "a-rather-long-field-name-here", "1")}{close(b)}", b, headed, 0)}")

    let counted: espresso.MultipartLimits = new espresso.MultipartLimits()
    counted.max_part_headers = 2
    io.println("too-many-headers {parse_chunked("--{b}{crlf()}Content-Disposition: form-data; name=\"a\"{crlf()}X-One: 1{crlf()}X-Two: 2{crlf()}{crlf()}v{crlf()}{close(b)}", b, counted, 0)}")

    let images: espresso.MultipartLimits = new espresso.MultipartLimits()
    images.allowed_file_types = ["image/png", "image/jpeg"]
    io.println("type-allowed {parse_chunked("{file_part(b, "f", "a.png", "image/png; charset=binary", "P")}{close(b)}", b, images, 0)}")
    io.println("type-refused {parse_chunked("{file_part(b, "f", "a.exe", "application/x-msdownload", "M")}{close(b)}", b, images, 0)}")
    io.println("type-list-ignores-fields {parse_chunked("--{b}{crlf()}Content-Disposition: form-data; name=\"a\"{crlf()}Content-Type: application/x-msdownload{crlf()}{crlf()}v{crlf()}{close(b)}", b, images, 0)}")

    io.println("-- content types --")
    for candidate: string in
        ["multipart/form-data; boundary=abc",
         "multipart/form-data; boundary=\"a b\"",
         "MULTIPART/FORM-DATA; BOUNDARY=abc",
         "multipart/form-data",
         "multipart/form-data; boundary=",
         "application/json",
         "",
         "multipart/form-data; boundary=0123456789012345678901234567890123456789012345678901234567890123456789X"] {
        match espresso.multipart_boundary(candidate) {
            ok(found) => { io.println("[{candidate}] -> [{found}]") }
            err(problem) => {
                io.println("[{candidate}] -> {problem.kind}: {problem.msg}")
            }
        }
    }

    // ---- reading a request ---------------------------------------------------

    io.println("-- read_multipart --")
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.post("/upload", upload).expect("upload")
    app.post("/counted", counted_upload).expect("counted")
    let host: espresso.TestHost = new espresso.TestHost(app)

    let headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "multipart/form-data; boundary={b}")
    let body: string =
        "{field(b, "title", "A report")}{field(b, "tag", "x")}{field(b, "tag", "y")}{file_part(b, "doc", "report.pdf", "application/pdf", "PDFBYTES")}{file_part(b, "doc", "second.pdf", "application/pdf", "MORE")}{close(b)}"
    let answer: espresso.TestResponse =
        host.send_with_headers("POST", "/upload", headers, body).expect("upload")
    io.println("upload {answer.status} {answer.text()}")

    let wrong_type: http.Headers = new http.Headers()
    wrong_type.add("Content-Type", "application/json")
    let refused: espresso.TestResponse = host.send_with_headers(
        "POST", "/upload", wrong_type, "\{\}").expect("wrong type")
    io.println("wrong-type {refused.status} {refused.text()}")

    let counted_answer: espresso.TestResponse = host.send_with_headers(
        "POST", "/counted", headers, body).expect("counted")
    io.println("custom-store {counted_answer.status} {counted_answer.text()}")

    host.close().expect("close")
}

fn upload(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let limits: espresso.MultipartLimits = new espresso.MultipartLimits()
    let form: espresso.MultipartForm =
        espresso.read_multipart(context.request, limits)?
    var shown: string = "fields {form.fields.count()}"
    for index: int in 0..form.fields.count() {
        shown = "{shown} {form.fields.name_at(index)}=[{form.fields.value_at(index)}]"
    }
    shown = "{shown} | files {form.files.len()}"
    var ids: List<string> = []
    for file: espresso.UploadedFile in form.files {
        // The storage id must be generated: 32 hex characters, unique per
        // part, and nothing to do with what the client submitted.
        var hex: bool = file.storage_id.len() == 32
        for index: int in 0..file.storage_id.len() {
            let byte: int = file.storage_id.byte_at(index)
            let digit: bool = byte >= 48 && byte <= 57
            let lower: bool = byte >= 97 && byte <= 102
            if !digit && !lower { hex = false }
        }
        if ids.contains(file.storage_id) { hex = false }
        ids.push(file.storage_id)
        shown = "{shown} [field={file.field} name={file.submitted_filename} type={file.declared_type} size={file.size} body={file.text()} id-ok={hex} id-is-name={file.storage_id == file.submitted_filename}]"
    }
    shown = "{shown} | tags {form.fields.all("tag").join(",")} first-doc {form.file("doc").is_some()} docs {form.files_for("doc").len()}"
    return espresso.text(shown)
}

// A store that keeps nothing: it counts the bytes and folds them into a
// checksum. It is here to prove the sink is a real extension point and not a
// hole shaped like the memory store.
pub class CountingSink implements espresso.PartSink {
    pub bytes: int = 0
    pub sum: int = 0
    pub closed: string = ""

    pub fn init() {}

    pub fn write(data: Bytes) -> Result<bool> {
        for index: int in 0..data.len() {
            self.bytes += 1
            self.sum = (self.sum * 31 + data.get(index)) % 1000003
        }
        return ok(true)
    }

    pub fn finish() -> Result<Bytes> {
        self.closed = "finished"
        return ok(new Bytes(0))
    }

    pub fn discard() { self.closed = "discarded" }
}

pub class CountingStore implements espresso.PartStore {
    pub sinks: List<CountingSink> = []
    pub ids: List<string> = []

    pub fn init() {}

    pub fn open(part: espresso.PartInfo,
                storage_id: string) -> Result<espresso.PartSink> {
        let sink: CountingSink = new CountingSink()
        self.sinks.push(sink)
        self.ids.push(storage_id)
        return ok(sink)
    }
}

fn counted_upload(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    let limits: espresso.MultipartLimits = new espresso.MultipartLimits()
    let store: CountingStore = new CountingStore()
    let form: espresso.MultipartForm =
        espresso.read_multipart_with(context.request, limits, store)?
    var shown: string = "sinks {store.sinks.len()}"
    for index: int in 0..store.sinks.len() {
        let sink: CountingSink = store.sinks[index]
        shown = "{shown} [bytes={sink.bytes} sum={sink.sum} state={sink.closed}]"
    }
    var kept: int = 0
    for file: espresso.UploadedFile in form.files {
        kept += file.text().len()
    }
    return espresso.text(
        "{shown} | records {form.files.len()} kept-bytes {kept} sizes {form.files.len()}")
}
