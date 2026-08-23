package main

import std.async as aio

async fn requested_lost() -> string {
    let requested: string = "GET"
    for value: int in [1] {
        if value == 1 {
            await aio.yield_now()
        }
    }
    return "method {requested}"
}

async fn main() {
    let ignored: string = await requested_lost()
}
