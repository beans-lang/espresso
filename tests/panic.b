package main

import espresso
import std.io
import std.log
import std.net
import std.thread

// The drill: a handler that panics must cost its request a 500, never the
// server, and the 500 must go through the SAME detailed_errors gate a
// returned err does — problem+json, a trace id, and the panic text kept off
// the wire in production. The three cases below pin every branch:
//
//   A  production default: the panic text and the "runtime panic at L:C"
//      position must not appear in the response; a trace id must; and the
//      record must reach stderr (test.sh greps it).
//   B  detailed_errors on: the panic text IS shown to the client.
//   C  a supplied log.Logger: the record goes there — with the SAME trace id
//      the client saw — and NOT to stderr (test.sh greps for its absence).
//
// Each case interpolates a distinct secret into its panic so the response and
// the two sinks can be told apart.

fn calm(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    return espresso.text("calm")
}

fn boom_a(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    panic("bad row alpha-4471-hunter2")
    return espresso.text("never reached")
}

fn boom_b(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    panic("bad row bravo-5582-swordfish")
    return espresso.text("never reached")
}

fn boom_c(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    panic("bad row charlie-6693-correcthorse")
    return espresso.text("never reached")
}

// The traceId the client was handed, pulled out of the problem+json body.
fn trace_of(reply: string) -> string {
    let marker: string = "\"traceId\":\""
    match reply.find(marker) {
        some(at) => {
            let rest: string = reply.slice(at + marker.len(), reply.len())
            match rest.find("\"") {
                some(end) => { return rest.slice(0, end) }
                none => { return "" }
            }
        }
        none => { return "" }
    }
}

fn get_reply(port: int, path: string) -> Result<string> {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 3000) {
        ok(stream) => {
            // A read timeout is the hang guard: read_to_end returns here only
            // because the panic response closes the connection (the
            // connection-fatal policy under test). Should a regression ever
            // keep the connection alive, the read fails after the timeout and
            // the assertions below turn false — the suite fails cleanly
            // instead of blocking forever.
            let armed: Result<bool> = stream.set_timeouts(3000, 3000)
            stream.write_text(
                "GET {path} HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")?
            return ok(stream.read_to_end(65536).or(new Bytes(0)).to_string())
        }
        err(error) => { return err(error.msg, error.kind) }
    }
}

// Case A — production default. No leak to the client, a trace id present, and
// the server still standing for ordinary traffic afterwards.
fn client_a(port: int, control: espresso.ServerControl) -> string {
    let boom: string = get_reply(port, "/boom").or("get-failed")
    let leak: bool =
        boom.contains("alpha-4471-hunter2") || boom.contains("runtime panic at")
    let problemjson: bool = boom.contains("application/problem+json")
    let traceid: bool = boom.contains("\"traceId\"")
    let status500: bool = boom.contains("500 Internal Server Error")
    let calm_reply: string = get_reply(port, "/calm").or("get-failed")
    let stood: bool =
        calm_reply.contains("200 OK") && calm_reply.contains("calm")
    let stopped: bool = control.stop().or(false)
    return "caseA leak {leak} problemjson {problemjson} traceid {traceid} status500 {status500} stood {stood} stopped {stopped}"
}

// Case B — detailed_errors on. The panic text is shown to the client, still
// as problem+json with a trace id.
fn client_b(port: int, control: espresso.ServerControl) -> string {
    let boom: string = get_reply(port, "/boom").or("get-failed")
    let shown: bool = boom.contains("bravo-5582-swordfish")
    let problemjson: bool = boom.contains("application/problem+json")
    let traceid: bool = boom.contains("\"traceId\"")
    let stopped: bool = control.stop().or(false)
    return "caseB shown {shown} problemjson {problemjson} traceid {traceid} stopped {stopped}"
}

// Case C — a supplied logger. The client must not see the secret; it reports
// the trace id it saw so main can prove the record carries the same one.
fn client_c(port: int, control: espresso.ServerControl) -> string {
    let boom: string = get_reply(port, "/boom").or("get-failed")
    let leaked: bool = boom.contains("charlie-6693-correcthorse")
    let trace: string = trace_of(boom)
    // Always stop the server, even on the leak path, so run_case_c's run()
    // returns and the record pull can run — a leak must fail the golden diff,
    // never hang the suite by leaving the server up.
    let stopped: bool = control.stop().or(false)
    if leaked { return "LEAKED" }
    if !stopped { return "STOP-FAILED" }
    return trace
}

fn run_case_a() -> string {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/calm", calm).expect("route")
    app.get("/boom", boom_a).expect("route")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client_a(port, control)
    })
    server.run().expect("run")
    return visitor.join()
}

fn run_case_b() -> string {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.options.detailed_errors = true
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/boom", boom_b).expect("route")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client_b(port, control)
    })
    server.run().expect("run")
    return visitor.join()
}

fn run_case_c() -> string {
    let exported: log.ExportSink = log.ExportSink.open().expect("sink")
    let logger: log.Logger = log.Logger.create(
        "espresso-panic-test", [exported.sink()]).expect("logger")
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    // detailed_errors stays false: the client still gets the generic body,
    // but the record now rides the supplied logger instead of stderr.
    builder.options.error_logger = some(logger)
    let app: espresso.WebApplication = builder.build().expect("app")
    app.get("/boom", boom_c).expect("route")
    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 100
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client_c(port, control)
    })
    server.run().expect("run")
    let client_trace: string = visitor.join()

    logger.flush().expect("flush")
    var record_secret: bool = false
    var record_trace: string = ""
    match exported.next(1000).expect("record") {
        some(record) => {
            record_secret = record.message.contains("charlie-6693-correcthorse")
            for field: log.Field in record.fields {
                if field.key == "traceId" { record_trace = field.value }
            }
        }
        none => {}
    }
    let leak: bool = client_trace == "LEAKED"
    let tracematch: bool =
        client_trace != "LEAKED" && client_trace != "STOP-FAILED" &&
        client_trace != "" && client_trace == record_trace
    return "caseC leak {leak} recordsecret {record_secret} tracematch {tracematch}"
}

fn main() {
    io.println(run_case_a())
    io.println(run_case_b())
    io.println(run_case_c())
}
