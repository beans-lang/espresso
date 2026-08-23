package main

import std.async as aio

class Chain {
    fn init() {}

    async fn step(index: int) -> Result<bool> {
        if index > 0 { return ok(true) }
        let next: async fn() -> Result<bool> =
            async fn() -> Result<bool> {
                return await self.step(index + 1)
            }
        return await next()
    }
}

async fn main() {
    let chain: Chain = new Chain()
    (await chain.step(0)).expect("step")
}
