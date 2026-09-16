// espresso's `add_services` wrapper: the scan is barista's, and what this
// asserts is that the wrapper registers into THIS builder's collection and
// that a scanned service resolves end to end through a request scope.
//
// The container's own behaviour — lifetimes, forwarding, cycles, captive
// scopes, disposal — is `barista/tests/`, and is not repeated here.
//
// Identity is a minted int rather than `==` on two references: reference
// equality does not build natively (beans `test/emitter_gaps.tsv:92`), and
// this suite runs on both backends.
package main

import github.com/beans-lang/barista
import espresso
import std.io

pub interface Clock {
    fn value() -> int
}

@barista.service(lifetime: barista.ServiceLifetime.singleton)
pub class SystemClock implements Clock {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        SystemClock.made += 1
        self.tag = SystemClock.made
    }
    pub fn value() -> int { return 7 }
}

pub interface Store {
    fn label() -> string
    fn stamp() -> int
}

// default lifetime: scoped; injected with another scanned service
@barista.service
pub class MemoryStore implements Store {
    static made: int = 0
    clock: Clock
    pub tag: int = 0

    pub fn init(clock: Clock) {
        self.clock = clock
        MemoryStore.made += 1
        self.tag = MemoryStore.made
    }
    pub fn label() -> string { return "store@{self.clock.value()}" }
    pub fn stamp() -> int { return self.tag }
}

@barista.service(lifetime: barista.ServiceLifetime.transient)
pub class Widget {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        Widget.made += 1
        self.tag = Widget.made
    }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let found: int = espresso.add_services(builder).expect("scan")
    io.println("scanned {found}")

    // The point of the wrapper: the registrations landed in THIS builder's
    // collection, so the application built from it can resolve them.
    let root: barista.ServiceProvider = builder.services.build_provider()
    let scope: barista.ServiceProvider = root.create_scope().expect("scope")
    let other: barista.ServiceProvider = root.create_scope().expect("other scope")

    let store_a: Store = scope.resolve<Store>().expect("store")
    let store_b: Store = scope.resolve<MemoryStore>().expect("memory store")
    let store_c: Store = other.resolve<Store>().expect("other store")
    io.println("scoped names {store_a.stamp() == store_b.stamp()}")
    io.println("scoped split {store_a.stamp() != store_c.stamp()}")
    io.println("injected {store_a.label()}")
    io.println("singleton built {SystemClock.made} across 2 scopes")

    let widget_a: Widget = scope.resolve<Widget>().expect("widget a")
    let widget_b: Widget = scope.resolve<Widget>().expect("widget b")
    io.println("transient split {widget_a.tag != widget_b.tag}")

    other.close().expect("close other")
    scope.close().expect("close scope")
    root.close().expect("close root")
}
