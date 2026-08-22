// @service discovery: lifetimes from the enum, registration as self and
// as each implemented interface, forwarding so every name shares one
// instance per scope, and constructor injection between scanned
// services.
package main

import espresso
import std.io

pub interface Clock {
    fn value() -> int
}

@espresso.service(lifetime: espresso.ServiceLifetime.singleton)
pub class SystemClock implements Clock {
    pub fn init() {}
    pub fn value() -> int { return 7 }
}

pub interface Store {
    fn label() -> string
}

// default lifetime: scoped; injected with another scanned service
@espresso.service
pub class MemoryStore implements Store {
    clock: Clock

    pub fn init(clock: Clock) { self.clock = clock }
    pub fn label() -> string { return "store@{self.clock.value()}" }
}

@espresso.service(lifetime: espresso.ServiceLifetime.transient)
pub class Widget {
    pub fn init() {}
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let found: int =
        espresso.add_services(builder).expect("scan")
    io.println("scanned {found}")

    let root: espresso.ServiceProvider =
        builder.services.build_provider()
    let scope: espresso.ServiceProvider =
        root.create_scope().expect("scope")
    let other: espresso.ServiceProvider =
        root.create_scope().expect("other scope")

    // a singleton is one instance under both of its names, everywhere
    let by_interface: Clock = scope.resolve<Clock>().expect("clock")
    let by_class: Clock =
        scope.resolve<SystemClock>().expect("system clock")
    let elsewhere: Clock = other.resolve<Clock>().expect("other clock")
    io.println("singleton names {by_interface == by_class}")
    io.println("singleton scopes {by_interface == elsewhere}")

    // a scoped service is one instance per scope across its names
    let store_a: Store = scope.resolve<Store>().expect("store")
    let store_b: Store =
        scope.resolve<MemoryStore>().expect("memory store")
    let store_c: Store = other.resolve<Store>().expect("other store")
    io.println("scoped names {store_a == store_b}")
    io.println("scoped split {store_a != store_c}")
    io.println("injected {store_a.label()}")

    // a transient is fresh every time
    let widget_a: Widget = scope.resolve<Widget>().expect("widget a")
    let widget_b: Widget = scope.resolve<Widget>().expect("widget b")
    io.println("transient split {widget_a != widget_b}")

    other.close().expect("close other")
    scope.close().expect("close scope")
    root.close().expect("close root")
}
