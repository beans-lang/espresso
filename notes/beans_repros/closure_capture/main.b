package main

import std.async as aio

fn one() -> int { return 1 }

async fn run_job<T implements Send>(move job: send fn() -> T) -> Result<T> {
    let finished: Channel<T> = new Channel(1)
    let work: send fn() = fn() move(job) {
        finished.send(job())
    }
    await aio.yield_now()
    work()
    return ok(finished.receive().expect("result"))
}

async fn main() {
    let job: send fn() -> int = one
    (await run_job(move job)).expect("job")
}
