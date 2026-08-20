package espresso

import std.encoding.json
import std.io
import std.time

pub enum LogLevel {
    trace
    debug
    info
    warn
    error
    none
}

fn log_level_value(level: LogLevel) -> int {
    return match level {
        trace => 0,
        debug => 1,
        info => 2,
        warn => 3,
        error => 4,
        none => 5,
    }
}

fn log_level_name(level: LogLevel) -> string {
    return match level {
        trace => "trace",
        debug => "debug",
        info => "info",
        warn => "warn",
        error => "error",
        none => "none",
    }
}

/// One structured log event.
pub class LogRecord {
    pub level: LogLevel
    pub event: string
    pub message: string
    pub trace_id: string
    pub fields: QueryValues = new QueryValues()
    pub monotonic_nanos: int = 0

    pub fn init(level: LogLevel,
                event: string,
                message: string,
                trace_id: string = "") {
        self.level = level
        self.event = event
        self.message = message
        self.trace_id = trace_id
        self.monotonic_nanos = time.monotonic_nanos()
    }

    pub fn field(name: string, value: string) -> LogRecord {
        self.fields.add(name, value)
        return self
    }
}

/// Small structured logger with a replaceable sink.
pub class Logger {
    minimum: LogLevel = LogLevel.info
    sink: fn(LogRecord)

    pub fn init() {
        self.sink = json_console_log
    }

    pub fn configure(minimum: LogLevel,
                     sink: fn(LogRecord)) -> Logger {
        self.minimum = minimum
        self.sink = sink
        return self
    }

    pub fn enabled(level: LogLevel) -> bool {
        return log_level_value(level) >= log_level_value(self.minimum) &&
               self.minimum != LogLevel.none
    }

    pub fn write(record: LogRecord) {
        if self.enabled(record.level) { self.sink(record) }
    }

    pub fn info(event: string, message: string, trace_id: string = "") {
        self.write(new LogRecord(LogLevel.info, event, message, trace_id))
    }

    pub fn warn(event: string, message: string, trace_id: string = "") {
        self.write(new LogRecord(LogLevel.warn, event, message, trace_id))
    }

    pub fn error(event: string, message: string, trace_id: string = "") {
        self.write(new LogRecord(LogLevel.error, event, message, trace_id))
    }
}

/// Default one-line JSON sink.
pub fn json_console_log(record: LogRecord) {
    let value: json.Value = json.Value.object()
    value.add("level", json.Value.from_string(
        log_level_name(record.level))).or(false)
    value.add("event", json.Value.from_string(record.event)).or(false)
    value.add("message", json.Value.from_string(record.message)).or(false)
    if record.trace_id != "" {
        value.add("traceId", json.Value.from_string(record.trace_id)).or(false)
    }
    for index: int in 0..record.fields.count() {
        value.add(record.fields.name_at(index),
                  json.Value.from_string(record.fields.value_at(index))).or(false)
    }
    io.println(json.stringify(value).or("\{\}"))
}

/// Logs request completion and duration around the rest of the pipeline.
pub fn request_logging(logger: Logger) ->
    fn(HttpContext, fn(HttpContext) -> Result<bool>) -> Result<bool> {
    return fn(context: HttpContext,
              next: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        let started: int = time.monotonic_nanos()
        let result: Result<bool> = next(context)
        let elapsed: int = time.monotonic_nanos() - started
        let record: LogRecord = new LogRecord(
            if result.is_ok() { LogLevel.info } else { LogLevel.error },
            "http.request",
            "{context.request.method} {context.request.path}",
            context.trace_id)
        record.field("status", "{context.response.status}")
        record.field("durationNanos", "{elapsed}")
        logger.write(record)
        return result
    }
}
