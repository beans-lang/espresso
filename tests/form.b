// application/x-www-form-urlencoded bodies: read directly, bound with @form,
// and refused when the body is something else.
package main

import espresso
import std.http
import std.io

@espresso.controller(route: "/signup")
pub class SignupController extends espresso.Controller {
    pub fn init() {}

    @espresso.post(route: "")
    pub fn create(@espresso.form name: string,
                  @espresso.form(name: "email_address") email: string,
                  @espresso.form(default: "30") days: int,
                  @espresso.form(required: false) referrer: string,
                  @espresso.form(default: "false") newsletter: bool) ->
        Result<espresso.ActionResult> {
        return self.ok_text(
            "name[{name}] email[{email}] days[{days}] referrer[{referrer}] news[{newsletter}]")
    }

    // A form field and a route value and a query field in one action, so the
    // three sources cannot be reading each other's storage.
    @espresso.post(route: r"/{group}")
    pub fn grouped(@espresso.route group: string,
                   @espresso.query(default: "-") tag: string,
                   @espresso.form name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text("group[{group}] tag[{tag}] name[{name}]")
    }
}

// The direct reader, without the binder in the way.
fn raw(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let fields: espresso.QueryValues = context.request.form()?
    var shown: string = "count:{fields.count()}"
    for index: int in 0..fields.count() {
        shown = "{shown} {fields.name_at(index)}=[{fields.value_at(index)}]"
    }
    return espresso.text(shown)
}

// The same request read as a form and as a query, to show they do not share
// a cache and that a repeated name stays repeated in both.
fn both(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
    let query: espresso.QueryValues = context.request.query()?
    let form: espresso.QueryValues = context.request.form()?
    return espresso.text(
        "query {query.count()} [{query.get("a").or("-")}] form {form.count()} [{form.get("a").or("-")}] all {form.all("a").join(",")}")
}

fn post(host: espresso.TestHost, label: string,
        target: string, content_type: string, body: string) {
    let headers: http.Headers = new http.Headers()
    if content_type != "" { headers.add("Content-Type", content_type) }
    let answer: espresso.TestResponse =
        host.send_with_headers("POST", target, headers, body).expect(label)
    io.println("{label} {answer.status} {answer.text()}")
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")
    app.post("/raw", raw).expect("raw")
    app.post("/both", both).expect("both")

    let host: espresso.TestHost = new espresso.TestHost(app)
    let form: string = "application/x-www-form-urlencoded"

    // The shapes the parser has to get right, one per line.
    post(host, "simple", "/raw", form, "a=1&b=2")
    post(host, "plus-is-space", "/raw", form, "a=hello+world")
    post(host, "percent", "/raw", form, "a=hello%20world%21")
    post(host, "newlines", "/raw", form, "note=line1%0D%0Aline2%09tabbed")
    post(host, "empty-value", "/raw", form, "a=&b=2")
    post(host, "no-equals", "/raw", form, "a&b=2")
    post(host, "repeated", "/raw", form, "a=1&a=2&a=3")
    post(host, "equals-in-value", "/raw", form, "a=1=2=3")
    post(host, "empty-body", "/raw", form, "")
    post(host, "utf8", "/raw", form, "a=caf%C3%A9")
    post(host, "charset-param", "/raw", "{form}; charset=UTF-8", "a=1")
    post(host, "uppercase-type", "/raw", "APPLICATION/X-WWW-FORM-URLENCODED",
         "a=1")
    post(host, "nul", "/raw", form, "a=%00")
    post(host, "bad-escape", "/raw", form, "a=%zz")
    post(host, "json-body", "/raw", "application/json", "a=1")
    post(host, "no-type", "/raw", "", "a=1")

    // A query string and a form body on the same request.
    post(host, "both", "/both?a=fromquery&a=second", form, "a=fromform&a=two")

    // The binder.
    post(host, "bound", "/signup", form,
         "name=Ada&email_address=ada%40example.test&days=7&newsletter=true&referrer=friend")
    post(host, "bound-defaults", "/signup", form,
         "name=Ada&email_address=ada%40example.test")
    post(host, "bound-missing", "/signup", form, "name=Ada")
    post(host, "bound-bad-int", "/signup", form,
         "name=Ada&email_address=a%40b.test&days=soon")
    post(host, "bound-wrong-type", "/signup", "application/json",
         "\{\"name\":\"Ada\"\}")
    post(host, "bound-three-sources", "/signup/team?tag=beta", form,
         "name=Ada")

    host.close().expect("close")
}
