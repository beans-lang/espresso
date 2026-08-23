package main

import std.async as aio

async fn branch_local() -> int {
    match some(1) {
        some(value) => {
            var total: int = value
            await aio.yield_now()
            total += 1
            return total
        }
        none => { return 0 }
    }
}

async fn loop_local() -> int {
    for true {
        var count: int = 0
        await aio.yield_now()
        count += 1
        return count
    }
    return 0
}

async fn main() {
    let first: int = await branch_local()
    let second: int = await loop_local()
}
