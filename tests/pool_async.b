package main

import espresso
import std.async as aio
import std.io

async fn run_job(pool: espresso.WorkerPool,
                 move job: send fn() -> int) -> string {
    match await pool.execute(move job) {
        ok(value) => { return "ok:{value}" }
        err(problem) => { return "err:{problem.kind}" }
    }
}

async fn close_pool(pool: espresso.WorkerPool) -> string {
    match await pool.close() {
        ok(_) => { return "closed" }
        err(problem) => { return "err:{problem.kind}" }
    }
}

async fn main() {
    let pool: espresso.WorkerPool =
        espresso.WorkerPool.start(1, 1).expect("pool")
    let gate: Channel<bool> = new Channel(1)
    let started: Channel<bool> = new Channel(1)
    let order: Channel<int> = new Channel(3)
    let ran: Atomic<int> = new Atomic<int>(0)
    let tasks: aio.TaskGroup<string> = new aio.TaskGroup<string>()

    tasks.start(run_job(pool, send fn() -> int {
        started.send(true)
        gate.receive().expect("gate")
        ran.fetch_add(1, MemoryOrder.relaxed)
        order.send(1)
        return 1
    }))
    let ignored_first: Option<string> = tasks.try_next()
    (await started.receive_async()).expect("started")

    tasks.start(run_job(pool, send fn() -> int {
        ran.fetch_add(10, MemoryOrder.relaxed)
        order.send(2)
        return 2
    }))
    let ignored_second: Option<string> = tasks.try_next()
    tasks.start(run_job(pool, send fn() -> int {
        ran.fetch_add(100, MemoryOrder.relaxed)
        order.send(3)
        return 3
    }))
    let ignored_third: Option<string> = tasks.try_next()

    // close marks the pool before it waits for the third, backpressured send.
    // Canceling this group then cancels that send and the first close call.
    tasks.start(close_pool(pool))
    let ignored_close: Option<string> = tasks.try_next()
    var rejected: bool = false
    match await pool.execute(send fn() -> int { return 99 }) {
        ok(_) => {}
        err(problem) => { rejected = problem.kind == "closed" }
    }
    tasks.cancel_all()

    gate.send(true)
    let closers: aio.TaskGroup<string> = new aio.TaskGroup<string>()
    closers.start(close_pool(pool))
    closers.start(close_pool(pool))
    let closes: List<string> = await closers.wait_all()
    let first: int = order.receive().expect("first")
    let second: int = order.receive().expect("second")
    let twice: bool = (await pool.close()).expect("second close")
    io.println("backpressure rejected {rejected}")
    io.println(
        "cancel late {ran.load(MemoryOrder.relaxed)} fifo {first},{second}")
    io.println("close concurrent {closes.join(",")} twice {twice}")

    // This close reaches the reaper wait before cancellation. The next close
    // must keep waiting on the same stored reaper and cached completion.
    let retry_pool: espresso.WorkerPool =
        espresso.WorkerPool.start(1, 1).expect("retry pool")
    let retry_gate: Channel<bool> = new Channel(1)
    let retry_started: Channel<bool> = new Channel(1)
    let retry_job: aio.TaskGroup<string> = new aio.TaskGroup<string>()
    retry_job.start(run_job(retry_pool, send fn() -> int {
        retry_started.send(true)
        retry_gate.receive().expect("retry gate")
        return 7
    }))
    let ignored_retry_job: Option<string> = retry_job.try_next()
    (await retry_started.receive_async()).expect("retry started")
    let abandoned_close: aio.TaskGroup<string> = new aio.TaskGroup<string>()
    abandoned_close.start(close_pool(retry_pool))
    let ignored_abandoned: Option<string> = abandoned_close.try_next()
    abandoned_close.cancel_all()
    retry_gate.send(true)
    let retried: bool = (await retry_pool.close()).expect("retry close")
    let ignored_result: List<string> = await retry_job.wait_all()
    io.println("reaper retry {retried}")
}
