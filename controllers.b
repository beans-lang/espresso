// Annotated controllers.
//
// A @controller class is discovered by scanning the reflection registry,
// registered as a scoped service, and each annotated action is compiled
// once into an ActionPlan — route pattern, parameter extractors, filters
// — so a request runs with no metadata lookups.
package espresso

import github.com/beans-lang/barista

import std.reflect

@target(value: ["type"])
@retention(value: "runtime")
pub annotation controller {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation get {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation post {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation put {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation patch {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation delete {
    route: string = ""
}

/// The optional base class for controllers: carries the request context
/// and the result helpers, so an action reads as
/// `return self.ok(json.encode(order)?)`. Deriving from it is a choice —
/// any class with action annotations is a controller.
pub class Controller {
    current: Option<HttpContext> = none

    /// Called by the dispatcher before the action runs.
    pub fn attach(context: HttpContext) {
        self.current = some(context)
    }

    /// The request being served. Only valid inside an action.
    pub fn context() -> HttpContext {
        return self.current.expect(
            "controller context outside a request")
    }

    /// 200 with an application/json body already encoded as text —
    /// pair it with json.encode(value).
    pub fn ok(encoded: string) -> Result<ActionResult> {
        return json_text(encoded)
    }

    /// 200 text/plain.
    pub fn ok_text(body_text: string) -> Result<ActionResult> {
        return text(body_text)
    }

    /// 201 with an application/json body.
    pub fn created(encoded: string) -> Result<ActionResult> {
        return created_json(encoded)
    }

    pub fn no_content() -> Result<ActionResult> {
        return no_content()
    }

    pub fn not_found() -> Result<ActionResult> {
        return not_found()
    }

    pub fn bad_request(detail: string) -> Result<ActionResult> {
        return problem(400, "Bad Request", detail)
    }

    pub fn problem(status: int, title: string,
                   detail: string) -> Result<ActionResult> {
        return problem(status, title, detail)
    }
}

class ControllerEndpoint {
    method: string
    route: string

    fn init(method: string, route: string) {
        self.method = method
        self.route = route
    }
}

fn annotation_string(annotation: reflect.Annotation,
                     field: string) -> Result<string> {
    match annotation.argument(field) {
        some(argument) => {
            return ok(argument.value().as_string().or(""))
        }
        none => { return ok("") }
    }
}

fn controller_annotation(type: reflect.Type) -> Option<reflect.Annotation> {
    for annotation: reflect.Annotation in type.annotations() {
        if annotation.qualified_name() == "espresso.controller" {
            return some(annotation)
        }
    }
    return none
}

fn endpoint_annotation(method: reflect.Method) -> Result<Option<ControllerEndpoint>> {
    var found: Option<ControllerEndpoint> = none
    for annotation: reflect.Annotation in method.annotations() {
        var verb: string = ""
        match annotation.qualified_name() {
            "espresso.get" => { verb = "GET" }
            "espresso.post" => { verb = "POST" }
            "espresso.put" => { verb = "PUT" }
            "espresso.patch" => { verb = "PATCH" }
            "espresso.delete" => { verb = "DELETE" }
            _ => {}
        }
        if verb == "" { continue }
        if found.is_some() {
            return err("controller action {method.name()} has more than one HTTP annotation", "controller")
        }
        found = some(new ControllerEndpoint(
            verb, annotation_string(annotation, "route")?))
    }
    return ok(move found)
}

fn controller_pattern(prefix: string, action: string) -> Result<string> {
    var left: string = prefix
    var right: string = action
    if left == "" { left = "/" }
    if !left.starts_with("/") {
        return err("controller route must start with /", "controller")
    }
    if left.len() > 1 && left.ends_with("/") {
        left = left.slice(0, left.len() - 1)
    }
    if right == "" { return ok(left) }
    if !right.starts_with("/") { right = "/{right}" }
    if left == "/" { return ok(right) }
    return ok("{left}{right}")
}

fn controller_filters(type: reflect.Type) -> List<reflect.Annotation> {
    var filters: List<reflect.Annotation> = []
    for annotation: reflect.Annotation in type.annotations() {
        let name: string = annotation.qualified_name()
        if name == "espresso.auth" || name == "espresso.validate" ||
           name == "espresso.limit" {
            filters.push(annotation)
        }
    }
    return move filters
}

/// Registers every linked controller as a scoped service. Call before build.
pub fn add_controllers(builder: WebApplicationBuilder) -> Result<int> {
    var count: int = 0
    for type: reflect.Type in reflect.types() {
        if controller_annotation(type).is_none() { continue }
        if type.kind() != reflect.Kind.class_type {
            return err("@controller can only mark a class", "controller")
        }
        builder.services.add(type, type, barista.ServiceLifetime.scoped)?
        count += 1
    }
    return ok(count)
}

/// Maps every annotated controller action. Call after build.
pub fn map_controllers(app: WebApplication) -> Result<int> {
    var count: int = 0
    let binder: Binder = new Binder()
    for type: reflect.Type in reflect.types() {
        match controller_annotation(type) {
            none => {}
            some(marker) => {
                let prefix: string = annotation_string(marker, "route")?
                let filters: List<reflect.Annotation> =
                    controller_filters(type)
                for method: reflect.Method in type.declared_methods() {
                    match endpoint_annotation(method)? {
                        none => {}
                        some(endpoint) => {
                            let plan: ActionPlan = build_action_plan(
                                type, method, some(marker),
                                filters, binder)?
                            app.map(
                                endpoint.method,
                                controller_pattern(prefix, endpoint.route)?,
                                fn(context: HttpContext) ->
                                    Result<ActionResult> {
                                    return plan.run(context)
                                })?
                            count += 1
                        }
                    }
                }
            }
        }
    }
    return ok(count)
}
