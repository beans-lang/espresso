package main

import espresso
import std.io

fn sink(record: espresso.LogRecord) {
    io.println("log {record.event} {record.message} {record.trace_id}")
}

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

    let logger: espresso.Logger = new espresso.Logger()
    logger.configure(espresso.LogLevel.info, sink)
    logger.info("startup", "ready", "trace-1")
}
