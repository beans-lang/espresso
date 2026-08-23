package espresso

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
    closed: bool = false

    fn init(jobs: Channel<send fn()>, move crew: List<Thread<bool>>) {
        self.jobs = jobs
        self.crew = move crew
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
        if self.closed { return err("the worker pool is closed", "closed") }
        let finished: Channel<T> = new Channel(1)
        let work: send fn() = fn() move(job) {
            finished.send(job())
        }
        await self.jobs.send_async(move work)
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
        self.closed = true
        self.jobs.close()
        for self.crew.len() > 0 {
            let worker: Thread<bool> = self.crew.pop().expect("pool thread")
            await worker.join_async()?
        }
        return ok(true)
    }
}
