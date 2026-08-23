package main

import std.async as aio
import std.reflect

fn problem(code: int, title: string, detail: string) -> Result<bool> {
    return err(detail, title)
}

class Target {
    pub fn init() {}
    pub async fn value() -> int {
        await aio.yield_now()
        return 1
    }
}

async fn invoke(method: reflect.Method,
                receiver: reflect.Value) -> Result<bool> {
    let called: Result<reflect.Value, reflect.ReflectError> =
        if method.is_async() {
            await method.call_async(receiver, [])
        } else {
            method.call(receiver, [])
        }
    match called {
        ok(_) => { return ok(true) }
        err(problem) => {
            return err("call failed: {problem.message()}", "reflect")
        }
    }
}

async fn main() {
    let method: reflect.Method =
        type_of(Target).method("value").expect("method")
    let receiver: reflect.Value = reflect.value(new Target())
    (await invoke(method, receiver)).expect("invoke")
}
