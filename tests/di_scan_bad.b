// A language `singleton class` cannot be container-activated: reflection
// exposes no callable initializer for it, so @service on one is refused
// at scan time with advice, not at first resolve with a mystery.
package main

import espresso
import std.io

@espresso.service
pub singleton class Highlander {
    pub fn greet() -> string { return "there can be only one" }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    match espresso.add_services(builder) {
        ok(_) => { io.println("scan accepted") }
        err(problem) => { io.println("scan {problem.kind}: {problem.msg}") }
    }
}
