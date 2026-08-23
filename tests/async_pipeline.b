package main

import espresso
import std.async as aio
import std.io
import std.log

class PipelineTrace {
    pub entries: List<string> = []

    pub fn init() {}
}

class ScopedDrop {
    dropped: Atomic<int>

    fn init(dropped: Atomic<int>) { self.dropped = dropped }

    fn deinit() { self.dropped.fetch_add(1, MemoryOrder.relaxed) }
}

async fn canceled_request(host: espresso.TestHost) -> bool {
    match await host.get("/cancel-scope") {
        ok(_) => { return false }
        err(_) => { return false }
    }
}

@espresso.controller(route: "/mixed")
pub class MixedController extends espresso.Controller {
    pub fn init() {}

    @espresso.get(route: "/sync")
    pub fn sync_action() -> Result<espresso.ActionResult> {
        return self.ok_text("sync")
    }

    @espresso.get(route: "/async")
    pub async fn async_action() -> Result<espresso.ActionResult> {
        await aio.yield_now()
        return self.ok_text("async")
    }
}

async fn broken(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    await aio.yield_now()
    return err("broken after a suspension", "handler")
}

fn unfinished(context: espresso.HttpContext) ->
    Result<espresso.ActionResult> {
    return espresso.detached()
}

fn logged_status(record: log.Record) -> string {
    for field: log.Field in record.fields {
        if field.key == "status" { return field.value }
    }
    return "missing"
}

async fn main() {
    let exported: log.ExportSink = log.ExportSink.open().expect("sink")
    let logger: log.Logger = log.Logger.create(
        "async-pipeline", [exported.sink()]).expect("logger")
    let trace: PipelineTrace = new PipelineTrace()
    let scope_started: Channel<bool> = new Channel(1)
    let scope_parked: aio.Event = new aio.Event()
    let scoped_drops: Atomic<int> = new Atomic<int>(0)
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_scoped_factory<ScopedDrop>(
        builder.services,
        fn(provider: espresso.ServiceProvider) -> Result<ScopedDrop> {
            return ok(new ScopedDrop(scoped_drops))
        }).expect("scoped drop")
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")
    app.use_middleware(new espresso.RequestLog(logger)).expect("request log")
    app.use(async fn(
            context: espresso.HttpContext,
            next: async fn(espresso.HttpContext) -> Result<bool>) ->
            Result<bool> {
        if context.request.path == "/mixed/async" {
            trace.entries.push("before")
            await aio.yield_now()
            let result: Result<bool> = await next(context)
            trace.entries.push("after")
            return result
        }
        return await next(context)
    }).expect("ordered middleware")
    app.use(async fn(
            context: espresso.HttpContext,
            next: async fn(espresso.HttpContext) -> Result<bool>) ->
            Result<bool> {
        if context.request.path == "/short" {
            trace.entries.push("short")
            context.response.text(200, "OK", "short")
            return ok(true)
        }
        return await next(context)
    }).expect("short middleware")
    espresso.map_controllers(app).expect("map controllers")
    app.get("/broken", broken).expect("broken route")
    app.get_sync("/unfinished", unfinished).expect("unfinished route")
    app.get("/cancel-scope", async fn(context: espresso.HttpContext) ->
            Result<espresso.ActionResult> {
        let held: ScopedDrop =
            context.services.resolve<ScopedDrop>()?
        scope_started.send(true)
        await scope_parked.wait()
        return espresso.text("unexpected")
    }).expect("cancel scope route")

    let host: espresso.TestHost = new espresso.TestHost(app)
    let sync_response: espresso.TestResponse =
        (await host.get("/mixed/sync")).expect("sync action")
    let async_response: espresso.TestResponse =
        (await host.get("/mixed/async")).expect("async action")
    let short_response: espresso.TestResponse =
        (await host.get("/short")).expect("short circuit")
    let broken_response: espresso.TestResponse =
        (await host.get("/broken")).expect("broken response")
    let unfinished_response: espresso.TestResponse =
        (await host.get("/unfinished")).expect("unfinished response")
    logger.flush().expect("flush")

    var broken_log_status: string = "missing"
    for index: int in 0..5 {
        match exported.next(1000).expect("record") {
            some(record) => {
                if record.message == "GET /broken" {
                    broken_log_status = logged_status(record)
                }
            }
            none => {}
        }
    }

    io.println(
        "controllers {sync_response.status}:{sync_response.text()} {async_response.status}:{async_response.text()}")
    io.println(
        "middleware {trace.entries.join(",")} response {short_response.status}:{short_response.text()}")
    io.println(
        "errors {broken_response.status} logged {broken_log_status} detached {unfinished_response.status}")

    let canceled: aio.TaskGroup<bool> = new aio.TaskGroup<bool>()
    canceled.start(canceled_request(host))
    let ignored_canceled: Option<bool> = canceled.try_next()
    (await scope_started.receive_async()).expect("scope started")
    canceled.cancel_all()
    io.println(
        "scope canceled dropped {scoped_drops.load(MemoryOrder.relaxed)}")
    host.close().expect("close")
}
