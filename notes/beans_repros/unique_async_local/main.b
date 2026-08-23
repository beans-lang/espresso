package main

import std.async as aio

unique class Handle {
    fn init() {}
    fn close() {}
}

fn open() -> Result<Handle> { return ok(new Handle()) }

async fn held_across_await() -> Result<bool> {
    let handle: Handle = open()?
    await aio.yield_now()
    handle.close()
    return ok(true)
}

async fn closed_before_await() -> Result<bool> {
    let handle: Handle = open()?
    handle.close()
    await aio.yield_now()
    return ok(true)
}

async fn main() {
    (await held_across_await()).expect("held")
    (await closed_before_await()).expect("closed")
}
