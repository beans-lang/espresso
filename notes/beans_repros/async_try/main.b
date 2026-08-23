package main

import std.async as aio

fn ready() -> Result<bool> { return ok(true) }

async fn propagate() -> Result<bool> {
    ready()?
    await aio.yield_now()
    return ok(true)
}

async fn main() {
    (await propagate()).expect("propagate")
}
