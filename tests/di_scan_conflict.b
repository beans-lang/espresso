// Two @service classes claiming the same interface is an error at scan
// time, never a silent last-wins.
package main

import espresso
import std.io

pub interface Mailer {
    fn send() -> string
}

@espresso.service
pub class SmtpMailer implements Mailer {
    pub fn init() {}
    pub fn send() -> string { return "smtp" }
}

@espresso.service
pub class LogMailer implements Mailer {
    pub fn init() {}
    pub fn send() -> string { return "log" }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    match espresso.add_services(builder) {
        ok(_) => { io.println("scan accepted") }
        err(problem) => { io.println("scan {problem.kind}: {problem.msg}") }
    }
}
