package main

import espresso
import std.io
import std.log

fn main() {
    let config: espresso.Configuration = new espresso.Configuration()
    config.set("server:host", "0.0.0.0").expect("host")
    config.set("server:port", "9000").expect("port")
    config.add_arguments([
        "--server:port=0",
        "--feature", "yes",
    ]).expect("args")

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    espresso.configure_server(config, options).expect("server config")
    io.println("server {options.host}:{options.port}")
    io.println("feature {config.boolean("feature", false).expect("feature")}")
    io.println("missing {config.integer("missing", 42).expect("fallback")}")
    match config.integer("feature", 0) {
        ok(_) => io.println("bad integer accepted"),
        err(error) => io.println("bad integer {error.kind}"),
    }

    // Espresso logs on std.log now. An ExportSink hands records back
    // through a pull reader, which keeps this test's output stable.
    let exported: log.ExportSink = log.ExportSink.open().expect("sink")
    let logger: log.Logger = log.Logger.create(
        "espresso-test", [exported.sink()]).expect("logger")
    logger.log_fields(
        log.Level.info, "ready",
        [new log.Field("event", "startup"),
         new log.Field("traceId", "trace-1")])
    logger.flush().expect("flush")
    match exported.next(1000).expect("record") {
        some(record) => {
            var event: string = ""
            var trace: string = ""
            for field: log.Field in record.fields {
                if field.key == "event" { event = field.value }
                if field.key == "traceId" { trace = field.value }
            }
            io.println("log {event} {record.message} {trace}")
        }
        none => { io.println("log missing") }
    }
}
