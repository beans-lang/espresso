package main

import std.async as aio

enum Event {
    body(value: Bytes)
    done
}

async fn consume(event: Event) -> Result<int> {
    match event {
        body(piece) => { return ok(piece.len()) }
        done => {
            await aio.yield_now()
            return ok(0)
        }
    }
}

async fn main() {
    (await consume(Event.body(Bytes.from("body")))).expect("body")
}
