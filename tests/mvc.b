// The object-oriented pipeline end to end: binding from every source,
// filters, base-class results, views, and the failure paths a client can
// actually trigger — wrong types, missing fields, bad JSON, unauthorized
// requests, exhausted rate limits.
package main

import espresso
import std.encoding.json
import std.http
import std.io

// ---- services --------------------------------------------------------------

pub interface Pricer {
    fn total(count: int) -> int
}

pub class UnitPricer implements Pricer {
    pub fn init() {}
    pub fn total(count: int) -> int { return count * 250 }
}

pub class KeyAuthorizer implements espresso.Authorizer {
    pub fn init() {}
    pub fn authorize(context: espresso.HttpContext,
                     policy: string) -> Result<bool> {
        let key: string =
            context.request.headers.get("X-Api-Key").or("")
        if policy == "admin" { return ok(key == "admin-key") }
        return ok(key != "")
    }
}

// ---- the bound body --------------------------------------------------------

pub class OrderRequest {
    pub sku: string
    pub count: int
    pub express: bool
    pub tags: List<string>

    pub fn init(move sku: string, count: int, express: bool,
                move tags: List<string>) {
        self.sku = move sku
        self.count = count
        self.express = express
        self.tags = move tags
    }

    pub fn validate(errors: espresso.ValidationErrors) {
        errors.required("sku", self.sku)
        errors.integer_range("count", self.count, 1, 100)
    }
}

pub class NoteRequest {
    pub text: string
    pub order: OrderRequest

    pub fn init(move text: string, move order: OrderRequest) {
        self.text = move text
        self.order = move order
    }
}

// ---- controllers -----------------------------------------------------------

@espresso.controller(route: "/orders")
pub class OrderController extends espresso.Controller {
    pricer: Pricer

    pub fn init(pricer: Pricer) { self.pricer = pricer }

    @espresso.get(route: r"/{id}")
    pub fn show(@espresso.route id: int,
                @espresso.query(default: "plain") style: string) ->
        Result<espresso.ActionResult> {
        if id == 404 { return self.not_found() }
        return self.ok_text("order {id} style {style}")
    }

    @espresso.get(route: r"/{id}/price")
    pub fn price(@espresso.route id: int,
                 @espresso.query count: int,
                 @espresso.header user_agent: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text(
            "order {id} total {self.pricer.total(count)} agent {user_agent}")
    }

    @espresso.validate
    @espresso.post(route: "")
    pub fn place(@espresso.body move order: OrderRequest) ->
        Result<espresso.ActionResult> {
        return espresso.text_status(
            201,
            "placed {order.sku} x{order.count} express {order.express} tags {order.tags.len()}")
    }

    @espresso.post(route: r"/{id}/notes")
    pub fn annotate(@espresso.route id: int,
                    @espresso.body move note: NoteRequest) ->
        Result<espresso.ActionResult> {
        return self.ok_text(
            "note on {id}: {note.text} for {note.order.sku}")
    }

    @espresso.get(route: r"/{id}/context")
    pub fn with_context(context: espresso.HttpContext,
                        @espresso.route id: int,
                        @espresso.inject pricer: Pricer) ->
        Result<espresso.ActionResult> {
        return self.ok_text(
            "trace {context.trace_id()} order {id} unit {pricer.total(1)}")
    }
}

@espresso.auth(policy: "admin")
@espresso.controller(route: "/admin")
pub class AdminController extends espresso.Controller {
    pub fn init() {}

    @espresso.get(route: "/panel")
    pub fn panel() -> Result<espresso.ActionResult> {
        return self.ok_text("the admin panel")
    }

    @espresso.limit(rpm: 2)
    @espresso.get(route: "/expensive")
    pub fn expensive() -> Result<espresso.ActionResult> {
        return self.ok_text("computed")
    }

    @espresso.get(route: "/report")
    pub fn report() -> Result<espresso.ActionResult> {
        return espresso.view(
            "report",
            ReportModel {
                title: "Weekly <Orders>",
                rows: [
                    ReportRow { name: "espresso", count: 3 },
                    ReportRow { name: "latte", count: 1 },
                ],
            })
    }
}

struct ReportRow {
    name: string
    count: int
}

struct ReportModel {
    title: string
    rows: List<ReportRow>
}

fn show(host: espresso.TestHost, label: string, method: string,
        target: string, body: string = "",
        key: string = "") -> Result<bool> {
    let headers: http.Headers = new http.Headers()
    if key != "" { headers.add("X-Api-Key", key) }
    if method != "GET" {
        headers.add("Content-Type", "application/json")
    }
    headers.add("User-Agent", "beans-test")
    let response: espresso.TestResponse =
        host.send_with_headers(method, target, headers, body)?
    io.println("{label} {response.status} [{response.text()}]")
    return ok(true)
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    builder.services.add_singleton<Pricer, UnitPricer>()
        .expect("pricer")
    builder.services.add_singleton<espresso.Authorizer, KeyAuthorizer>()
        .expect("authorizer")
    let views: espresso.Views = new espresso.Views()
    views.add(
        "report",
        "<h1>\{\{title\}\}</h1><ul>\{\{#rows\}\}<li>\{\{name\}\}=\{\{count\}\}</li>\{\{/rows\}\}</ul>\{\{^rows\}\}<p>empty</p>\{\{/rows\}\}")
        .expect("template")
    espresso.add_views(builder, views).expect("views")
    io.println("registered {espresso.add_controllers(builder).expect("add")}")
    let app: espresso.WebApplication = builder.build().expect("app")
    io.println("mapped {espresso.map_controllers(app).expect("map")}")

    let host: espresso.TestHost = new espresso.TestHost(app)

    // binding from route, query defaults, headers
    show(host, "show", "GET", "/orders/7").expect("show")
    show(host, "styled", "GET", "/orders/7?style=fancy").expect("styled")
    show(host, "missing", "GET", "/orders/404").expect("missing")
    show(host, "price", "GET", "/orders/7/price?count=4").expect("price")
    // type errors from the client answer 400, not 500
    show(host, "bad-route", "GET", "/orders/seven").expect("bad route")
    show(host, "bad-query", "GET", "/orders/7/price?count=lots")
        .expect("bad query")
    show(host, "no-query", "GET", "/orders/7/price").expect("no query")

    // body binding: valid, invalid JSON, wrong shape, failed validation
    show(host, "place", "POST", "/orders",
         "\{\"sku\":\"beans-1\",\"count\":2,\"express\":true,\"tags\":[\"a\",\"b\"]\}")
        .expect("place")
    show(host, "bad-json", "POST", "/orders", "\{not json")
        .expect("bad json")
    show(host, "wrong-shape", "POST", "/orders",
         "\{\"sku\":\"beans-1\",\"count\":\"two\",\"express\":true,\"tags\":[]\}")
        .expect("wrong shape")
    show(host, "missing-field", "POST", "/orders",
         "\{\"sku\":\"beans-1\",\"count\":2,\"express\":false\}")
        .expect("missing field")
    show(host, "invalid", "POST", "/orders",
         "\{\"sku\":\"\",\"count\":500,\"express\":false,\"tags\":[]\}")
        .expect("invalid")
    // nested object binding
    show(host, "note", "POST", "/orders/9/notes",
         "\{\"text\":\"rush it\",\"order\":\{\"sku\":\"beans-2\",\"count\":1,\"express\":false,\"tags\":[]\}\}")
        .expect("note")

    // context + injected service parameters
    show(host, "context", "GET", "/orders/3/context").expect("context")

    // auth filter: missing key, wrong key, right key
    show(host, "auth-none", "GET", "/admin/panel").expect("auth none")
    show(host, "auth-wrong", "GET", "/admin/panel", "", "user-key")
        .expect("auth wrong")
    show(host, "auth-ok", "GET", "/admin/panel", "", "admin-key")
        .expect("auth ok")

    // rate limit: two pass, the third answers 429 with Retry-After
    show(host, "limit-1", "GET", "/admin/expensive", "", "admin-key")
        .expect("limit one")
    show(host, "limit-2", "GET", "/admin/expensive", "", "admin-key")
        .expect("limit two")
    let limited_headers: http.Headers = new http.Headers()
    limited_headers.add("X-Api-Key", "admin-key")
    let limited: espresso.TestResponse = host.send_with_headers(
        "GET", "/admin/expensive", limited_headers).expect("limited")
    io.println(
        "limit-3 {limited.status} retry {limited.headers.get("Retry-After").or("none")}")

    // the view result renders escaped HTML with sections
    let report_headers: http.Headers = new http.Headers()
    report_headers.add("X-Api-Key", "admin-key")
    let report: espresso.TestResponse = host.send_with_headers(
        "GET", "/admin/report", report_headers).expect("report")
    io.println("report {report.status} [{report.text()}]")
    io.println(
        "report-type {report.headers.get("Content-Type").or("none")}")

    host.close().expect("close")
}
