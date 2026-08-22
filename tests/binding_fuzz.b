// Adversarial model binding: seeded generators aim malformed bodies,
// hostile query strings and wrong-typed values at one bound endpoint.
// The invariant is blunt — every request answers 200, 400 or 404, never
// a 500, never a panic — and well-formed bodies must round-trip. The
// final tallies are the golden output, so a behavior change in either
// direction fails loudly.
package main

import espresso
import std.encoding.json
import std.http
import std.io

pub class Payload {
    pub name: string
    pub count: int
    pub ratio: float
    pub live: bool
    pub tags: List<string>
    pub scores: List<int>

    pub fn init(move name: string, count: int, ratio: float,
                live: bool, move tags: List<string>,
                move scores: List<int>) {
        self.name = move name
        self.count = count
        self.ratio = ratio
        self.live = live
        self.tags = move tags
        self.scores = move scores
    }

    pub fn validate(errors: espresso.ValidationErrors) {
        errors.length("name", self.name, 1, 32)
        errors.integer_range("count", self.count, 0, 1000)
    }
}

pub class Inner {
    pub label: string
    pub fn init(move label: string) { self.label = move label }
}

pub class Outer {
    pub inner: Inner
    pub depth: int
    pub fn init(move inner: Inner, depth: int) {
        self.inner = move inner
        self.depth = depth
    }
}

@espresso.controller(route: "/fuzz")
pub class FuzzController extends espresso.Controller {
    pub fn init() {}

    @espresso.validate
    @espresso.post(route: "/payload")
    pub fn payload(@espresso.body move payload: Payload) ->
        Result<espresso.ActionResult> {
        return self.ok_text(
            "{payload.name}|{payload.count}|{payload.live}|{payload.tags.len()}|{payload.scores.len()}")
    }

    @espresso.post(route: "/nested")
    pub fn nested(@espresso.body move outer: Outer) ->
        Result<espresso.ActionResult> {
        return self.ok_text("{outer.inner.label}@{outer.depth}")
    }

    @espresso.get(route: "/typed/\{id\}")
    pub fn typed(@espresso.route id: int,
                 @espresso.query(required: false) flag: bool,
                 @espresso.query(default: "7") level: int) ->
        Result<espresso.ActionResult> {
        return self.ok_text("{id}:{flag}:{level}")
    }
}

// A tiny deterministic generator: xorshift over the seed.
class Rand {
    state: int

    fn init(seed: int) { self.state = seed * 2654435761 + 1 }

    fn next(bound: int) -> int {
        var value: int = self.state
        value = value ^ (value * 8192)
        value = value ^ (value / 131072)
        value = value ^ (value * 32)
        self.state = value
        var reduced: int = value % bound
        if reduced < 0 { reduced += bound }
        return reduced
    }
}

fn fragment(chaos: Rand) -> string {
    let choices: List<string> = [
        "\"name\":\"ok\"", "\"name\":42", "\"name\":null",
        "\"count\":5", "\"count\":\"five\"", "\"count\":-3",
        "\"count\":99999999999", "\"ratio\":1.5", "\"ratio\":\"x\"",
        "\"live\":true", "\"live\":\"yes\"",
        "\"tags\":[\"a\",\"b\"]", "\"tags\":[1,2]", "\"tags\":\"solo\"",
        "\"scores\":[1,2,3]", "\"scores\":[\"a\"]", "\"scores\":\{\}",
        "\"extra\":\{\"deep\":[[[1]]]\}", "\"name\":\"",
    ]
    return choices[chaos.next(choices.len())]
}

fn body_for(chaos: Rand) -> string {
    let shape: int = chaos.next(8)
    if shape == 0 { return "" }
    if shape == 1 { return "not json at all" }
    if shape == 2 { return "[1,2,3]" }
    if shape == 3 { return "\{" }
    if shape == 4 { return "null" }
    var built: string = "\{"
    let pieces: int = chaos.next(6) + 1
    for index: int in 0..pieces {
        if index != 0 { built = "{built}," }
        built = "{built}{fragment(chaos)}"
    }
    return "{built}\}"
}

fn query_for(chaos: Rand) -> string {
    let choices: List<string> = [
        "", "?flag=true", "?flag=banana", "?level=9",
        "?level=", "?level=%41", "?flag=1&level=3",
        "?flag=true&flag=false", "?level=99999999999999999999",
        "?%6c%65%76%65%6c=5",
    ]
    return choices[chaos.next(choices.len())]
}

fn route_for(chaos: Rand) -> string {
    let choices: List<string> = [
        "12", "0", "-4", "twelve", "1e3", "0x10", "999999999999",
        "12%20", "%31%32",
    ]
    return choices[chaos.next(choices.len())]
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_controllers(builder).expect("add")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")
    let host: espresso.TestHost = new espresso.TestHost(app)

    let chaos: Rand = new Rand(20260822)
    var ok_count: int = 0
    var client_error: int = 0
    var other: int = 0
    let headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "application/json")

    for round: int in 0..400 {
        let lane: int = chaos.next(3)
        var status: int = 0
        if lane == 0 {
            status = host.send_with_headers(
                "POST", "/fuzz/payload", headers,
                body_for(chaos)).expect("payload").status
        } else if lane == 1 {
            status = host.send_with_headers(
                "POST", "/fuzz/nested", headers,
                body_for(chaos)).expect("nested").status
        } else {
            status = host.get(
                "/fuzz/typed/{route_for(chaos)}{query_for(chaos)}")
                .expect("typed").status
        }
        if status == 200 { ok_count += 1 }
        else if status == 400 || status == 404 { client_error += 1 }
        else { other += 1 }
    }
    io.println(
        "fuzz rounds 400 ok {ok_count} client-errors {client_error} unexpected {other}")

    // Well-formed requests round-trip exactly, fuzz aside.
    let good: espresso.TestResponse = host.send_with_headers(
        "POST", "/fuzz/payload", headers,
        "\{\"name\":\"beans\",\"count\":3,\"ratio\":0.5,\"live\":true,\"tags\":[\"x\"],\"scores\":[9,8]\}")
        .expect("good")
    io.println("good {good.status} [{good.text()}]")
    let nested: espresso.TestResponse = host.send_with_headers(
        "POST", "/fuzz/nested", headers,
        "\{\"inner\":\{\"label\":\"deep\"\},\"depth\":2\}")
        .expect("nested good")
    io.println("nested {nested.status} [{nested.text()}]")
    io.println("typed {host.get("/fuzz/typed/5?flag=true").expect("typed").text()}")
    io.println("typed-default {host.get("/fuzz/typed/5").expect("typed2").text()}")
    host.close().expect("close")
}
