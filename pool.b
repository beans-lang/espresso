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

fn spawn_pool_reaper(move workers: List<Thread<bool>>,
                     done: Channel<Result<bool>>) -> Thread<bool> {
    return thread.spawn(fn() move(workers) -> bool {
        var failed_message: string = ""
        var failed_kind: string = ""
        for workers.len() > 0 {
            let worker: Thread<bool> = workers.pop().expect("pool thread")
            if !worker.join() && failed_message == "" {
                failed_message = "a worker returned failure while closing"
                failed_kind = "worker"
            }
        }
        if failed_message == "" {
            done.send(ok(true))
        } else {
            done.send(err(failed_message, failed_kind))
        }
        return true
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
    reaper_started: bool = false
    reapers: List<Thread<bool>> = []
    reaper_done: Channel<Result<bool>> = new Channel(1)
    close_failed_message: string = ""
    close_failed_kind: string = ""

    fn init(jobs: Channel<send fn()>, move crew: List<Thread<bool>>) {
        self.jobs = jobs
        self.crew = move crew
        self.senders_drained.set()
        self.close_released.set()
    }

    fn cached_close_result() -> Result<bool> {
        if self.close_failed_message != "" {
            return err(self.close_failed_message, self.close_failed_kind)
        }
        return ok(true)
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
        if self.closed { return self.cached_close_result() }

        for self.close_running {
            let released: aio.Event = self.close_released
            await released.wait()
            if self.closed { return self.cached_close_result() }
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
        if !self.reaper_started {
            var workers: List<Thread<bool>> = []
            for self.crew.len() > 0 {
                workers.push(self.crew.pop().expect("pool thread"))
            }
            self.reapers.push(spawn_pool_reaper(
                move workers, self.reaper_done))
            self.reaper_started = true
        }
        match await self.reaper_done.receive_async() {
            some(result) => {
                match result {
                    ok(_) => {}
                    err(problem) => {
                        self.close_failed_message = problem.msg
                        self.close_failed_kind = problem.kind
                    }
                }
            }
            none => {
                self.close_failed_message =
                    "the worker reaper stopped without a result"
                self.close_failed_kind = "worker"
            }
        }
        if self.reapers.len() > 0 {
            let reaper: Thread<bool> =
                self.reapers.pop().expect("pool reaper")
            if !reaper.join() && self.close_failed_message == "" {
                self.close_failed_message =
                    "the worker reaper returned failure"
                self.close_failed_kind = "worker"
            }
        }
        self.closed = true
        return self.cached_close_result()
    }
}
