// Middleware as objects.
//
// A function is still a middleware — app.use takes one — but an object
// carries configuration and state without a capturing closure, and a
// package can export one type instead of a factory function. The two
// forms compose in one pipeline in registration order.
package espresso

import std.log
import std.time

/// One pipeline layer. handle() calls next(context) to continue, or
/// answers the response itself and returns without calling it.
pub interface Middleware {
    fn handle(context: HttpContext,
              next: fn(HttpContext) -> Result<bool>) -> Result<bool>
}

/// Logs one line per request on a std.log logger: method, path, status
/// and duration, at info for success and error for a failed pipeline.
pub class RequestLog implements Middleware {
    logger: log.Logger

    pub fn init(logger: log.Logger) { self.logger = logger }

    pub fn handle(context: HttpContext,
                  next: fn(HttpContext) -> Result<bool>) -> Result<bool> {
        let started: int = time.monotonic_nanos()
        let result: Result<bool> = next(context)
        let elapsed: int = time.monotonic_nanos() - started
        let level: log.Level = if result.is_ok() {
            log.Level.info
        } else {
            log.Level.error
        }
        if self.logger.enabled(level) {
            self.logger.log_fields(
                level,
                "{context.request.method} {context.request.path}",
                [new log.Field("status", "{context.response.status}"),
                 new log.Field("durationNanos", "{elapsed}"),
                 new log.Field("traceId", context.trace_id())])
        }
        return result
    }
}

/// A ready console logger for the common case: info level, one stderr
/// sink. Build your own log.Logger for files, rotation or JSON shape.
pub fn console_logger(name: string = "espresso") -> Result<log.Logger> {
    return log.Logger.create_with_level(
        name, [log.Sink.console()?], log.Level.info)
}
