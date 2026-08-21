package espresso

import std.thread

// The crew loop lives in its own function so the closure captures a function
// parameter — the shared Channel handle — rather than a loop local.
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

/// A fixed crew of threads draining one job queue. Blocking work belongs
/// here, never on the event loop: a handler calls `context.respond_later()`,
/// moves the Responder into a job, and submits the job. Each worker's
/// application needs its own pool — the pool handle is loop-local even
/// though its jobs are Send.
pub class WorkerPool {
    jobs: Channel<send fn()>
    crew: List<Thread<bool>> = []
    closed: bool = false

    fn init(jobs: Channel<send fn()>, move crew: List<Thread<bool>>) {
        self.jobs = jobs
        self.crew = move crew
    }

    /// Starts `workers` threads over a queue that holds `queue_depth`
    /// waiting jobs. A full queue makes `submit` block — backpressure,
    /// never loss.
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

    /// Queues one job for the crew. Anything the job must answer travels
    /// inside it as a moved Responder.
    pub fn submit(move job: send fn()) -> Result<bool> {
        if self.closed { return err("the worker pool is closed", "closed") }
        self.jobs.send(move job)
        return ok(true)
    }

    /// Closes the queue, lets already-queued jobs finish, and joins the crew.
    pub fn close() -> Result<bool> {
        if self.closed { return ok(true) }
        self.closed = true
        self.jobs.close()
        for self.crew.len() > 0 {
            let worker: Thread<bool> = self.crew.pop().expect("pool thread")
            let finished: bool = worker.join()
        }
        return ok(true)
    }
}
