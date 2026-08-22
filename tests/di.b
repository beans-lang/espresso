package main

import espresso
import std.io

pub interface Clock {
    fn value() -> int
}

pub class FixedClock implements Clock {
    pub fn init() {}
    pub fn value() -> int { return 42 }
}

pub class Greeter {
    clock: Clock

    pub fn init(clock: Clock) {
        self.clock = clock
    }

    pub fn message() -> string { return "hello {self.clock.value()}" }
}

pub class RequestMarker {
    pub fn init() {}
}

pub class TransientMarker {
    pub fn init() {}
}

pub class FactoryMarker {
    pub fn init() {}
}

pub class CycleA {
    pub fn init(value: CycleB) {}
}

pub class CycleB {
    pub fn init(value: CycleA) {}
}

pub class BadSingleton {
    pub fn init(marker: RequestMarker) {}
}

fn make_factory(provider: espresso.ServiceProvider) -> Result<FactoryMarker> {
    return ok(new FactoryMarker())
}

fn main() {
    let services: espresso.ServiceCollection = new espresso.ServiceCollection()
    services.add_singleton<Clock, FixedClock>().expect("clock")
    services.transient<Greeter>().expect("greeter")
    services.scoped<RequestMarker>().expect("marker")
    services.transient<TransientMarker>().expect("transient")
    services.transient<CycleA>().expect("cycle a")
    services.transient<CycleB>().expect("cycle b")
    services.singleton<BadSingleton>().expect("bad singleton")
    espresso.add_singleton_factory(services, make_factory).expect("factory")

    let root: espresso.ServiceProvider = services.build_provider()
    let scope: espresso.ServiceProvider = root.create_scope().expect("scope")
    let greeter: Greeter = scope.resolve<Greeter>().expect("resolve greeter")
    let first: RequestMarker = scope.resolve<RequestMarker>().expect("first marker")
    let second: RequestMarker = scope.resolve<RequestMarker>().expect("second marker")
    let transient_first: TransientMarker = scope.resolve<TransientMarker>().expect("transient one")
    let transient_second: TransientMarker = scope.resolve<TransientMarker>().expect("transient two")
    let factory_first: FactoryMarker = scope.resolve<FactoryMarker>().expect("factory one")

    let other_scope: espresso.ServiceProvider = root.create_scope().expect("other scope")
    let other_marker: RequestMarker = other_scope.resolve<RequestMarker>().expect("other marker")
    let factory_second: FactoryMarker = other_scope.resolve<FactoryMarker>().expect("factory two")

    io.println(greeter.message())
    io.println("scoped same {first == second}")
    io.println("scoped split {first != other_marker}")
    io.println("transient split {transient_first != transient_second}")
    io.println("singleton same {factory_first == factory_second}")
    match root.resolve<RequestMarker>() {
        ok(_) => io.println("root scope accepted"),
        err(error) => io.println("root scope {error.kind}"),
    }
    match scope.resolve<CycleA>() {
        ok(_) => io.println("cycle accepted"),
        err(error) => io.println("cycle {error.kind}"),
    }
    match scope.resolve<BadSingleton>() {
        ok(_) => io.println("captive scope accepted"),
        err(error) => io.println("captive scope {error.kind}"),
    }
    other_scope.close().expect("close other scope")
    scope.close().expect("close scope")
    root.close().expect("close root")
    match root.create_scope() {
        ok(_) => io.println("closed root accepted"),
        err(error) => io.println("closed root {error.kind}"),
    }
}
