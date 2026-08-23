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
    (await pool.close()).expect("resumed close")
    let first: int = order.receive().expect("first")
    let second: int = order.receive().expect("second")
    let twice: bool = (await pool.close()).expect("second close")
    io.println("backpressure rejected {rejected}")
    io.println(
        "cancel late {ran.load(MemoryOrder.relaxed)} fifo {first},{second}")
    io.println("close twice {twice}")
}
