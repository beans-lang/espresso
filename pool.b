package espresso

import std.async as aio
import std.thread

fn spawn_pool_worker(jobs: Channel<send fn()>) -> Thread<bool> {
    return thread.spawn(fn() -> bool {
        for {
            match jobs.receive() {
                some(work) => { work() }
                none => { return true }
            }
        }
    })
}

/// A fixed crew for blocking or CPU-heavy work. `execute` parks only the
/// calling async handler; a pool thread runs the job and returns its value.
pub class WorkerPool {
    jobs: Channel<send fn()>
    crew: List<Thread<bool>> = []
    closing: bool = false
    jobs_closed: bool = false
    closed: bool = false
    pending_sends: int = 0
    senders_drained: aio.Event = new aio.Event()
    close_running: bool = false
    close_released: aio.Event = new aio.Event()

    fn init(jobs: Channel<send fn()>, move crew: List<Thread<bool>>) {
        self.jobs = jobs
        self.crew = move crew
        self.senders_drained.set()
        self.close_released.set()
    }

    pub static fn start(workers: int,
                        queue_depth: int = 256) -> Result<WorkerPool> {
        if workers <= 0 || queue_depth <= 0 {
            return err("a worker pool needs positive workers and queue depth",
                       "config")
        }
        let jobs: Channel<send fn()> = new Channel(queue_depth)
        var crew: List<Thread<bool>> = []
        for index: int in 0..workers {
            crew.push(spawn_pool_worker(jobs))
        }
        return ok(new WorkerPool(jobs, move crew))
    }

    /// Runs one Send job on the fixed crew and asynchronously waits for its
    /// result. The bounded work channel provides backpressure without
    /// blocking the async executor.
    pub async fn execute<T implements Send>(move job: send fn() -> T) ->
        Result<T> {
        if self.closing { return err("the worker pool is closed", "closed") }
        let finished: Channel<T> = new Channel(1)
        let work: send fn() = fn() move(job) {
            finished.send(job())
        }
        if self.pending_sends == 0 {
            self.senders_drained = new aio.Event()
        }
        self.pending_sends += 1
        var sending: bool = true
        defer {
            if sending {
                self.pending_sends -= 1
                if self.pending_sends == 0 { self.senders_drained.set() }
            }
        }
        await self.jobs.send_async(move work)
        sending = false
        self.pending_sends -= 1
        if self.pending_sends == 0 { self.senders_drained.set() }
        match await finished.receive_async() {
            some(value) => { return ok(move value) }
            none => {
                return err("the worker stopped without a result", "worker")
            }
        }
    }

    /// Closes the queue, drains accepted work, and asynchronously joins the
    /// fixed crew.
    pub async fn close() -> Result<bool> {
        if self.closed { return ok(true) }

        for self.close_running {
            let released: aio.Event = self.close_released
            await released.wait()
            if self.closed { return ok(true) }
        }
        self.close_running = true
        self.close_released = new aio.Event()
        defer {
            self.close_running = false
            self.close_released.set()
        }

        self.closing = true
        if self.pending_sends > 0 {
            let drained: aio.Event = self.senders_drained
            await drained.wait()
        }
        if !self.jobs_closed {
            self.jobs.close()
            self.jobs_closed = true
        }
        for self.crew.len() > 0 {
            let worker: Thread<bool> = self.crew.pop().expect("pool thread")
            var joined: bool = false
            defer {
                if !joined { self.crew.push(move worker) }
            }
            let result: Result<bool> = await worker.join_async()
            joined = true
            result?
        }
        self.closed = true
        return ok(true)
    }
}
