package espresso

import std.reflect

@target(value: ["type"])
@retention(value: "runtime")
pub annotation controller {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation http_get {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation http_post {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation http_put {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation http_patch {
    route: string = ""
}

@target(value: ["method"])
@retention(value: "runtime")
pub annotation http_delete {
    route: string = ""
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
            "espresso.http_get" => { verb = "GET" }
            "espresso.http_post" => { verb = "POST" }
            "espresso.http_put" => { verb = "PUT" }
            "espresso.http_patch" => { verb = "PATCH" }
            "espresso.http_delete" => { verb = "DELETE" }
            _ => {}
        }
        if verb == "" { continue }
        if found.is_some() {
            return err("controller method {method.name()} has more than one HTTP annotation", "controller")
        }
        found = some(new ControllerEndpoint(
            verb, annotation_string(annotation, "route")?))
    }
    return ok(found)
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

fn validate_controller_method(method: reflect.Method) -> Result<bool> {
    if !method.is_public() || method.is_static() ||
       method.is_async() || method.is_generic() {
        return err("controller method {method.name()} must be public, synchronous, instance, and non-generic", "controller")
    }
    let parameters: List<reflect.Parameter> = method.parameters()
    if parameters.len() != 1 ||
       parameters[0].type().qualified_name() !=
           type_of(HttpContext).qualified_name() ||
       parameters[0].passing() != reflect.Passing.borrowed {
        return err("controller method {method.name()} must take one borrowed HttpContext", "controller")
    }
    if method.result_type().qualified_name() !=
           type_of(Result<bool>).qualified_name() {
        return err("controller method {method.name()} must return Result<bool>", "controller")
    }
    return ok(true)
}

fn controller_handler(controller_type: reflect.Type,
                      method: reflect.Method) ->
    fn(HttpContext) -> Result<bool> {
    return fn(context: HttpContext) -> Result<bool> {
        let receiver: reflect.Value =
            context.services.resolve_value(controller_type)?
        var returned: Option<reflect.Value> = none
        match method.call(receiver, [reflect.value(context)]) {
            ok(value) => { returned = some(value) }
            err(problem) => {
                return err(
                    "controller {controller_type.qualified_name()}.{method.name()} failed: {problem.message()}",
                    "controller")
            }
        }
        let boxed: reflect.Value = returned.expect("controller result")
        match boxed as? Result<bool> {
            some(result) => { return result }
            none => {
                return err("controller returned the wrong runtime type", "controller")
            }
        }
    }
}

/// Registers every linked controller as a scoped service. Call before build.
pub fn add_controllers(builder: WebApplicationBuilder) -> Result<int> {
    var count: int = 0
    for type: reflect.Type in reflect.types() {
        if controller_annotation(type).is_none() { continue }
        if type.kind() != reflect.Kind.class_type {
            return err("@controller can only mark a class", "controller")
        }
        builder.services.add_scoped(type, type)?
        count += 1
    }
    return ok(count)
}

/// Maps every annotated controller method. Call after build.
pub fn map_controllers(app: WebApplication) -> Result<int> {
    var count: int = 0
    for type: reflect.Type in reflect.types() {
        match controller_annotation(type) {
            none => {}
            some(marker) => {
                let prefix: string = annotation_string(marker, "route")?
                for method: reflect.Method in type.declared_methods() {
                    match endpoint_annotation(method)? {
                        none => {}
                        some(endpoint) => {
                            validate_controller_method(method)?
                            app.map(
                                endpoint.method,
                                controller_pattern(prefix, endpoint.route)?,
                                controller_handler(type, method))?
                            count += 1
                        }
                    }
                }
            }
        }
    }
    return ok(count)
}
