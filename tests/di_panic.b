package main

// Issue #3, the DI half. resolve_value pushes a name onto `resolving` and bumps
// `singleton_depth` around the factory call, which runs a user constructor that
// can panic. The espresso server brews every handler, so that panic is
// contained — and the bookkeeping must be released on the unwind, or the same
// provider is poisoned for later resolves. This drives exactly that: a
// singleton whose constructor panics is resolved (contained) on a scope, then
// the SAME scope is used again.
//
//   with the defer fix:      first panic:panic  second panic:panic  third ok
//   without it (reverted):   first panic:panic  second err:service_cycle
//                            third err:scope
//
// i.e. a stranded `resolving` entry turns the second resolve into a false
// "dependency cycle", and a stuck `singleton_depth` turns the scoped resolve
// into a false "singleton cannot capture scoped". Both backends must agree.

import espresso
import std.io

class PanicSingleton {
    pub fn init() { panic("singleton constructor blew up") }
}

class OkScoped {
    pub fn init() {}
}

fn try_singleton(scope: espresso.ServiceProvider) -> Result<PanicSingleton> {
    return scope.resolve<PanicSingleton>()
}

// Resolve the panicking singleton on a brewed fiber and report how it ended:
// "panic:<kind>" if the constructor's panic surfaced at the join, or
// "err:<kind>" if resolve_value returned an ordinary error first.
fn describe(scope: espresso.ServiceProvider) -> string {
    let child: Brew<Result<PanicSingleton>> = brew try_singleton(scope)
    match child.join() {
        ok(inner) => {
            match inner {
                ok(_) => { return "resolved" }
                err(problem) => { return "err:{problem.kind}" }
            }
        }
        err(problem) => { return "panic:{problem.kind}" }
    }
}

fn main() {
    let services: espresso.ServiceCollection =
        new espresso.ServiceCollection()
    services.singleton<PanicSingleton>().expect("register singleton")
    services.scoped<OkScoped>().expect("register scoped")
    let root: espresso.ServiceProvider = services.build_provider()
    let scope: espresso.ServiceProvider = root.create_scope().expect("scope")

    // First contained panic strands the bookkeeping without the fix.
    io.println("first {describe(scope)}")
    // Second resolve: with the fix the factory runs again and panics; without
    // it, the stranded `resolving` entry short-circuits to a false cycle error.
    io.println("second {describe(scope)}")
    // A scoped resolve on the same scope: with the fix singleton_depth is back
    // to zero and it resolves; without it the stuck depth rejects it.
    match scope.resolve<OkScoped>() {
        ok(_) => { io.println("third ok") }
        err(problem) => { io.println("third err:{problem.kind}") }
    }

    let closed: Result<bool> = scope.close()
    let closed_root: Result<bool> = root.close()
}
