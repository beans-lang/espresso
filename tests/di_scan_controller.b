// The one thing espresso's `add_services` does that barista's cannot: refuse
// `@barista.service` on a `@controller`.
//
// A controller is already registered as a scoped service by `add_controllers`.
// A second registration under the same name would silently replace the first,
// with whatever lifetime the annotation asked for — a singleton controller
// holding one request's context for the life of the process, for instance. So
// it is an error at scan time.
//
// This refusal had no test at all before the container moved out. It was
// written, shipped, and never exercised.
package main

import github.com/beans-lang/barista
import espresso
import std.io

@espresso.controller(route: r"/things")
@barista.service
pub class ThingsController extends espresso.Controller {
    pub fn init() {}

    @espresso.get(route: r"")
    pub fn index() -> Result<espresso.ActionResult> {
        return espresso.text("things")
    }
}

/// The positive control, and the whole reason this file can tell "refused for
/// its own reason" from "refused for a coarser one". It is an ordinary
/// `@service` in the same scan, and it must be ACCEPTED — which it can only
/// report if the scan reaches it, so it also proves the refusal above is not
/// simply "the scan failed".
@barista.service
pub class OrdinaryService {
    pub fn init() {}
    pub fn label() -> string { return "ordinary" }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    match espresso.add_services(builder) {
        ok(count) => { io.println("scan accepted {count}") }
        err(problem) => { io.println("scan {problem.kind}: {problem.msg}") }
    }

    // The control, registered by hand this time, to show the refusal above was
    // about the @controller and not about the scan being broken.
    let clean: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    clean.services.scoped<OrdinaryService>().expect("ordinary")
    let root: barista.ServiceProvider = clean.services.build_provider()
    let scope: barista.ServiceProvider = root.create_scope().expect("scope")
    let made: OrdinaryService = scope.resolve<OrdinaryService>().expect("resolve")
    io.println("the control resolves {made.label()}")
    scope.close().expect("close")
    root.close().expect("close root")
}
