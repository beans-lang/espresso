// Model binding and action filters.
//
// Everything here happens in two phases. At map time the controller
// scanner reads each action's parameter annotations once and compiles
// them into a plan — typed extractors, a body construction recipe per
// DTO, the filters — so a request executes the plan with no metadata
// lookups. At request time the plan pulls route values, query fields,
// headers, the JSON body and services, invokes the action, and hands its
// ActionResult back to the router.
package espresso

import std.encoding.json
import std.reflect
import std.time

// ---- the binding annotations ----------------------------------------------

/// Binds a parameter from a route value: @route on `id: int` reads
/// `{id}`. `name` overrides the route parameter looked up.
@target(value: ["parameter"])
@retention(value: "runtime")
pub annotation route {
    name: string = ""
}

/// Binds a parameter from the query string. Missing fields answer 400
/// unless a `default` is given.
@target(value: ["parameter"])
@retention(value: "runtime")
pub annotation query {
    name: string = ""
    default: string = ""
    required: bool = true
}

/// Binds a parameter from a request header. Underscores in the parameter
/// name become dashes: `user_agent` reads `user-agent`.
@target(value: ["parameter"])
@retention(value: "runtime")
pub annotation header {
    name: string = ""
    required: bool = false
}

/// Binds a parameter from the JSON request body, constructed through the
/// type's initializer with fields matched by name.
@target(value: ["parameter"])
@retention(value: "runtime")
pub annotation body {}

/// Resolves a parameter from the request's service scope.
@target(value: ["parameter"])
@retention(value: "runtime")
pub annotation inject {}

// ---- the filter annotations -----------------------------------------------

/// Requires the registered Authorizer to allow the request. On a
/// controller the policy applies to every action; an action's own @auth
/// wins over the controller's.
@target(value: ["type", "method"])
@retention(value: "runtime")
pub annotation auth {
    policy: string = ""
}

/// Runs each bound @body value's `validate(errors)` method and answers
/// 400 with the collected problems when any are recorded.
@target(value: ["type", "method"])
@retention(value: "runtime")
pub annotation validate {}

/// Fixed-window rate limit for one action, counted per worker. On a
/// controller the limit applies to each of its actions separately.
@target(value: ["type", "method"])
@retention(value: "runtime")
pub annotation limit {
    rpm: int = 60
}

/// The authorization decision point @auth calls. Register an
/// implementation as a service; requests under @auth answer 500 until
/// one is registered, and 403 when it declines.
pub interface Authorizer {
    fn authorize(context: HttpContext, policy: string) -> Result<bool>
}

// ---- results the filters answer with --------------------------------------

class ValidationResult implements ActionResult {
    errors: ValidationErrors

    fn init(errors: ValidationErrors) { self.errors = errors }

    pub fn execute(context: HttpContext) -> Result<bool> {
        return write_validation_problem(context, self.errors)
    }
}

class RetryAfterResult implements ActionResult {
    seconds: int

    fn init(seconds: int) { self.seconds = seconds }

    pub fn execute(context: HttpContext) -> Result<bool> {
        context.response.header("Retry-After", "{self.seconds}")
        let produced: ProblemResult = new ProblemResult(
            429, "Too Many Requests",
            "The rate limit for this endpoint was reached.")
        return produced.execute(context)
    }
}

// ---- value conversions -----------------------------------------------------

// Conversion codes for scalars bound from text or JSON.
// 0 int, 1 float, 2 bool, 3 string.
fn scalar_kind(name: string) -> int {
    if name == "int" { return 0 }
    if name == "float" { return 1 }
    if name == "bool" { return 2 }
    if name == "string" { return 3 }
    return -1
}

// The zero of each bindable scalar, for optional parameters left out.
fn zero_value(kind: int) -> reflect.Value {
    if kind == 0 { return reflect.value(0) }
    if kind == 1 { return reflect.value(0.0) }
    if kind == 2 { return reflect.value(false) }
    return reflect.value("")
}

fn text_to_value(text: string, kind: int,
                 shown: string) -> Result<reflect.Value> {
    if kind == 0 {
        match text.to_int() {
            ok(number) => { return ok(reflect.value(number)) }
            err(_) => {
                return err("{shown} must be an integer, got '{text}'",
                           "bad_request")
            }
        }
    }
    if kind == 1 {
        match text.to_float() {
            ok(number) => { return ok(reflect.value(number)) }
            err(_) => {
                return err("{shown} must be a number, got '{text}'",
                           "bad_request")
            }
        }
    }
    if kind == 2 {
        if text == "true" || text == "1" {
            return ok(reflect.value(true))
        }
        if text == "false" || text == "0" {
            return ok(reflect.value(false))
        }
        return err("{shown} must be true or false, got '{text}'",
                   "bad_request")
    }
    return ok(reflect.value(text))
}

// ---- the JSON body recipe --------------------------------------------------

// One initializer parameter of a bound DTO.
// kind: 0..3 scalar, 4 list, 5 nested DTO.
class BodyField {
    name: string
    kind: int
    element_kind: int
    nested: int
    element_nested: int

    fn init(name: string, kind: int, element_kind: int,
            nested: int, element_nested: int) {
        self.name = name
        self.kind = kind
        self.element_kind = element_kind
        self.nested = nested
        self.element_nested = element_nested
    }
}

class BodyPlan {
    type: reflect.Type
    initializer: reflect.Initializer
    fields: List<BodyField> = []
    validator: Option<reflect.Method> = none

    fn init(type: reflect.Type, initializer: reflect.Initializer) {
        self.type = type
        self.initializer = initializer
    }
}

/// Compiles and executes JSON-body construction recipes. One binder is
/// shared by every mapped controller, so a DTO used by several actions
/// compiles once.
class Binder {
    plans: List<BodyPlan> = []
    plan_index: Map<string, int> = {}

    fn plan_for(type: reflect.Type) -> Result<int> {
        let name: string = type.qualified_name()
        match self.plan_index.get(name) {
            some(index) => { return ok(index) }
            none => {}
        }
        if type.kind() != reflect.Kind.class_type &&
           type.kind() != reflect.Kind.struct_type {
            return err(
                "@body needs a class or struct, got {name}", "binding")
        }
        var initializer: Option<reflect.Initializer> = none
        match type.initializer() {
            some(found) => { initializer = some(found) }
            none => {
                return err(
                    "@body type {name} has no public initializer",
                    "binding")
            }
        }
        let made: BodyPlan = new BodyPlan(
            type, initializer.expect("initializer"))
        // Register before recursing, so a type that mentions itself
        // compiles once instead of forever.
        let index: int = self.plans.len()
        self.plans.push(made)
        self.plan_index[name] = index
        for parameter: reflect.Parameter in
            made.initializer.parameters() {
            let parameter_type: reflect.Type = parameter.type()
            let type_name: string = parameter_type.qualified_name()
            var kind: int = scalar_kind(type_name)
            var element_kind: int = -1
            var nested: int = -1
            var element_nested: int = -1
            if kind < 0 {
                if type_name.starts_with("List<") &&
                   type_name.ends_with(">") {
                    kind = 4
                    let arguments: List<reflect.Type> =
                        parameter_type.type_arguments()
                    if arguments.len() != 1 {
                        return err(
                            "@body field {parameter.name()} has an unsupported list type {type_name}",
                            "binding")
                    }
                    element_kind = scalar_kind(
                        arguments[0].qualified_name())
                    if element_kind < 0 {
                        element_nested =
                            self.plan_for(arguments[0])?
                        element_kind = 5
                    }
                } else {
                    nested = self.plan_for(parameter_type)?
                    kind = 5
                }
            }
            made.fields.push(new BodyField(
                parameter.name(), kind, element_kind,
                nested, element_nested))
        }
        match type.method("validate") {
            some(found) => {
                let parameters: List<reflect.Parameter> =
                    found.parameters()
                if parameters.len() == 1 &&
                   parameters[0].type().qualified_name() ==
                       type_of(ValidationErrors).qualified_name() {
                    made.validator = some(found)
                }
            }
            none => {}
        }
        return ok(index)
    }

    fn field_value(plan_name: string, field: BodyField,
                   node: json.Value) -> Result<reflect.Value> {
        let shown: string = "{plan_name}.{field.name}"
        if field.kind == 0 {
            match node.to_int() {
                ok(number) => { return ok(reflect.value(number)) }
                err(_) => {
                    return err("{shown} must be an integer",
                               "bad_request")
                }
            }
        }
        if field.kind == 1 {
            match node.number() {
                ok(number) => { return ok(reflect.value(number)) }
                err(_) => {
                    return err("{shown} must be a number", "bad_request")
                }
            }
        }
        if field.kind == 2 {
            match node.to_bool() {
                ok(flag) => { return ok(reflect.value(flag)) }
                err(_) => {
                    return err("{shown} must be a boolean", "bad_request")
                }
            }
        }
        if field.kind == 3 {
            match node.to_string() {
                ok(text) => { return ok(reflect.value(text)) }
                err(_) => {
                    return err("{shown} must be a string", "bad_request")
                }
            }
        }
        if field.kind == 4 {
            return self.list_value(shown, field, node)
        }
        return self.construct(field.nested, node)
    }

    fn list_value(shown: string, field: BodyField,
                  node: json.Value) -> Result<reflect.Value> {
        if node.kind() != json.Kind.array {
            return err("{shown} must be an array", "bad_request")
        }
        let elements: List<json.Value> = node.elements()?
        if field.element_kind == 0 {
            var values: List<int> = []
            for element: json.Value in elements {
                match element.to_int() {
                    ok(number) => { values.push(number) }
                    err(_) => {
                        return err("{shown} must hold integers",
                                   "bad_request")
                    }
                }
            }
            return ok(reflect.value(move values))
        }
        if field.element_kind == 1 {
            var values: List<float> = []
            for element: json.Value in elements {
                match element.number() {
                    ok(number) => { values.push(number) }
                    err(_) => {
                        return err("{shown} must hold numbers",
                                   "bad_request")
                    }
                }
            }
            return ok(reflect.value(move values))
        }
        if field.element_kind == 2 {
            var values: List<bool> = []
            for element: json.Value in elements {
                match element.to_bool() {
                    ok(flag) => { values.push(flag) }
                    err(_) => {
                        return err("{shown} must hold booleans",
                                   "bad_request")
                    }
                }
            }
            return ok(reflect.value(move values))
        }
        if field.element_kind == 3 {
            var values: List<string> = []
            for element: json.Value in elements {
                match element.to_string() {
                    ok(text) => { values.push(text) }
                    err(_) => {
                        return err("{shown} must hold strings",
                                   "bad_request")
                    }
                }
            }
            return ok(reflect.value(move values))
        }
        return err(
            "{shown}: lists of objects are bound one level deep only — bind the outer object and validate inside",
            "binding")
    }

    fn construct(plan: int, node: json.Value) -> Result<reflect.Value> {
        let recipe: BodyPlan = self.plans[plan]
        let plan_name: string = recipe.type.name()
        if node.kind() != json.Kind.object {
            return err("{plan_name} must be a JSON object", "bad_request")
        }
        var arguments: List<reflect.Value> = []
        for field: BodyField in recipe.fields {
            match node.get(field.name) {
                some(child) => {
                    arguments.push(self.field_value(
                        plan_name, field, child)?)
                }
                none => {
                    return err(
                        "{plan_name}.{field.name} is required",
                        "bad_request")
                }
            }
        }
        match recipe.initializer.call(move arguments) {
            ok(value) => { return ok(value) }
            err(problem) => {
                return err(
                    "cannot construct {plan_name}: {problem.message()}",
                    "binding")
            }
        }
    }

    fn run_validator(plan: int,
                     value: reflect.Value,
                     errors: ValidationErrors) -> Result<bool> {
        let recipe: BodyPlan = self.plans[plan]
        match recipe.validator {
            some(method) => {
                match method.call(value, [reflect.value(errors)]) {
                    ok(_) => { return ok(true) }
                    err(problem) => {
                        return err(
                            "{recipe.type.name()}.validate failed: {problem.message()}",
                            "binding")
                    }
                }
            }
            none => { return ok(true) }
        }
    }

    fn has_validator(plan: int) -> bool {
        return self.plans[plan].validator.is_some()
    }
}

// ---- per-action plans ------------------------------------------------------

// One bound parameter. kind: 0 context, 1 route, 2 query, 3 header,
// 4 body, 5 service.
class ArgPlan {
    kind: int
    name: string
    shown: string
    fallback: string
    has_fallback: bool
    required: bool
    value_kind: int
    body_plan: int
    service: Option<reflect.Type> = none

    fn init(kind: int, name: string, shown: string) {
        self.kind = kind
        self.name = name
        self.shown = shown
        self.fallback = ""
        self.has_fallback = false
        self.required = true
        self.value_kind = 3
        self.body_plan = -1
    }
}

class ActionPlan {
    controller: reflect.Type
    action: reflect.Method
    arguments: List<ArgPlan> = []
    attach_context: bool = false
    auth_policy: string = ""
    has_auth: bool = false
    validate_body: bool = false
    limit_rpm: int = 0
    window_start: int = 0
    window_count: int = 0
    binder: Binder

    fn init(controller: reflect.Type,
            action: reflect.Method,
            binder: Binder) {
        self.controller = controller
        self.action = action
        self.binder = binder
    }

    fn over_limit() -> bool {
        if self.limit_rpm <= 0 { return false }
        let now: int = time.monotonic_nanos()
        if now - self.window_start >= 60_000_000_000 {
            self.window_start = now
            self.window_count = 0
        }
        self.window_count += 1
        return self.window_count > self.limit_rpm
    }

    fn authorize(context: HttpContext) -> Result<Option<ActionResult>> {
        if !self.has_auth { return ok(none) }
        var boxed: Option<reflect.Value> = none
        match context.services.resolve_value(type_of(Authorizer)) {
            ok(value) => { boxed = some(value) }
            err(_) => {
                return ok(some(new ProblemResult(
                    500, "Internal Server Error",
                    "@auth needs an Authorizer service registered.")))
            }
        }
        match boxed.expect("authorizer") as? Authorizer {
            some(authorizer) => {
                if !authorizer.authorize(context, self.auth_policy)? {
                    return ok(some(new ProblemResult(
                        403, "Forbidden",
                        "The request was not authorized.")))
                }
                return ok(none)
            }
            none => {
                return ok(some(new ProblemResult(
                    500, "Internal Server Error",
                    "The registered Authorizer has the wrong type.")))
            }
        }
    }

    fn bind_argument(plan: ArgPlan,
                     context: HttpContext,
                     parsed_body: json.Value,
                     errors: ValidationErrors) -> Result<reflect.Value> {
        if plan.kind == 0 { return ok(reflect.value(context)) }
        if plan.kind == 1 {
            match context.request.route(plan.name) {
                some(text) => {
                    return text_to_value(
                        text, plan.value_kind, plan.shown)
                }
                none => {
                    return err(
                        "route value {plan.name} is missing for {plan.shown}",
                        "binding")
                }
            }
        }
        if plan.kind == 2 {
            let fields: QueryValues = context.request.query()?
            match fields.get(plan.name) {
                some(text) => {
                    return text_to_value(
                        text, plan.value_kind, plan.shown)
                }
                none => {
                    if plan.has_fallback {
                        if plan.fallback == "" {
                            return ok(zero_value(plan.value_kind))
                        }
                        return text_to_value(
                            plan.fallback, plan.value_kind, plan.shown)
                    }
                    return err("{plan.shown} is required", "bad_request")
                }
            }
        }
        if plan.kind == 3 {
            match context.request.headers.get(plan.name) {
                some(text) => {
                    return text_to_value(
                        text, plan.value_kind, plan.shown)
                }
                none => {
                    if plan.required {
                        return err(
                            "header {plan.name} is required",
                            "bad_request")
                    }
                    return text_to_value(
                        "", plan.value_kind, plan.shown)
                }
            }
        }
        if plan.kind == 4 {
            let value: reflect.Value =
                self.binder.construct(plan.body_plan, parsed_body)?
            if self.validate_body {
                self.binder.run_validator(
                    plan.body_plan, value, errors)?
            }
            return ok(value)
        }
        let service_type: reflect.Type =
            plan.service.expect("service type")
        return context.services.resolve_value(service_type)
    }

    fn needs_body() -> bool {
        for plan: ArgPlan in self.arguments {
            if plan.kind == 4 { return true }
        }
        return false
    }

    fn run(context: HttpContext) -> Result<ActionResult> {
        if self.over_limit() {
            let limited: ActionResult = new RetryAfterResult(60)
            return ok(limited)
        }
        match self.authorize(context)? {
            some(refusal) => { return ok(refusal) }
            none => {}
        }
        var parsed_body: json.Value = json.Value.null()
        if self.needs_body() {
            match json.parse_bytes(context.request.body) {
                ok(value) => { parsed_body = value }
                err(_) => {
                    let invalid: ActionResult = new ProblemResult(
                        400, "Bad Request",
                        "The request body is not valid JSON.")
                    return ok(invalid)
                }
            }
        }
        let errors: ValidationErrors = new ValidationErrors()
        var arguments: List<reflect.Value> = []
        for plan: ArgPlan in self.arguments {
            match self.bind_argument(
                plan, context, parsed_body, errors) {
                ok(value) => { arguments.push(value) }
                err(problem) => {
                    if problem.kind == "bad_request" {
                        let refused: ActionResult = new ProblemResult(
                            400, "Bad Request", problem.msg)
                        return ok(refused)
                    }
                    return err(problem.msg, problem.kind)
                }
            }
        }
        if self.validate_body && !errors.is_valid() {
            let failed: ActionResult = new ValidationResult(errors)
            return ok(failed)
        }
        let receiver: reflect.Value =
            context.services.resolve_value(self.controller)?
        if self.attach_context {
            match receiver as? Controller {
                some(base) => { base.attach(context) }
                none => {}
            }
        }
        var returned: Option<reflect.Value> = none
        match self.action.call(receiver, move arguments) {
            ok(value) => { returned = some(value) }
            err(problem) => {
                return err(
                    "controller {self.controller.qualified_name()}.{self.action.name()} failed: {problem.message()}",
                    "controller")
            }
        }
        match returned.expect("action result") as? Result<ActionResult> {
            some(result) => { return result }
            none => {
                return err(
                    "controller action returned the wrong runtime type",
                    "controller")
            }
        }
    }
}

fn parameter_marker(parameter: reflect.Parameter) ->
    Result<Option<reflect.Annotation>> {
    var found: Option<reflect.Annotation> = none
    for annotation: reflect.Annotation in parameter.annotations() {
        let name: string = annotation.qualified_name()
        if name != "espresso.route" && name != "espresso.query" &&
           name != "espresso.header" && name != "espresso.body" &&
           name != "espresso.inject" {
            continue
        }
        if found.is_some() {
            return err(
                "parameter {parameter.name()} has more than one binding annotation",
                "binding")
        }
        found = some(annotation)
    }
    return ok(move found)
}

fn header_name(raw: string) -> string {
    var result: string = ""
    for index: int in 0..raw.len() {
        let byte: int = raw.byte_at(index)
        if byte == 95 {
            result = "{result}-"
        } else {
            result = "{result}{raw.slice(index, index + 1)}"
        }
    }
    return result
}

// Annotation arguments materialize their declared defaults, so an empty
// string means "not written" for the name-like fields here.
fn annotation_text(annotation: reflect.Annotation,
                   field: string, fallback: string) -> string {
    match annotation.argument(field) {
        some(argument) => {
            let written: string = argument.value().as_string().or("")
            return if written == "" { fallback } else { written }
        }
        none => { return fallback }
    }
}

fn annotation_number(annotation: reflect.Annotation,
                     field: string, fallback: int) -> int {
    match annotation.argument(field) {
        some(argument) => {
            return argument.value().as_int().or(fallback)
        }
        none => { return fallback }
    }
}

fn annotation_flag(annotation: reflect.Annotation,
                   field: string, fallback: bool) -> bool {
    match annotation.argument(field) {
        some(argument) => {
            return argument.value().as_bool().or(fallback)
        }
        none => { return fallback }
    }
}

// Builds one action's plan from its reflected signature. Every problem
// here is a map-time error: a bad annotation never becomes a 500 later.
fn build_action_plan(controller: reflect.Type,
                     action: reflect.Method,
                     marker: Option<reflect.Annotation>,
                     controller_filters: List<reflect.Annotation>,
                     binder: Binder) -> Result<ActionPlan> {
    if !action.is_public() || action.is_static() ||
       action.is_async() || action.is_generic() {
        return err(
            "controller action {action.name()} must be public, synchronous, instance, and non-generic",
            "controller")
    }
    if action.result_type().qualified_name() !=
           type_of(Result<ActionResult>).qualified_name() {
        return err(
            "controller action {action.name()} must return Result<ActionResult>",
            "controller")
    }
    let plan: ActionPlan = new ActionPlan(controller, action, binder)
    plan.attach_context = type_of(Controller).is_assignable_from(controller)

    let context_name: string = type_of(HttpContext).qualified_name()
    for parameter: reflect.Parameter in action.parameters() {
        if parameter.passing() == reflect.Passing.mutable {
            return err(
                "controller action parameter {parameter.name()} cannot be inout",
                "controller")
        }
        let parameter_type: reflect.Type = parameter.type()
        let type_name: string = parameter_type.qualified_name()
        let shown: string = "{action.name()}.{parameter.name()}"
        match parameter_marker(parameter)? {
            none => {
                if type_name == context_name {
                    plan.arguments.push(new ArgPlan(0, "", shown))
                    continue
                }
                return err(
                    "parameter {parameter.name()} of {action.name()} needs a binding annotation — @route, @query, @header, @body or @inject",
                    "binding")
            }
            some(annotation) => {
                let marker_name: string = annotation.qualified_name()
                if marker_name == "espresso.route" {
                    let bound: ArgPlan = new ArgPlan(
                        1,
                        annotation_text(
                            annotation, "name", parameter.name()),
                        shown)
                    bound.value_kind = scalar_kind(type_name)
                    if bound.value_kind < 0 {
                        return err(
                            "@route parameter {parameter.name()} must be int, float, bool or string",
                            "binding")
                    }
                    plan.arguments.push(bound)
                } else if marker_name == "espresso.query" {
                    let bound: ArgPlan = new ArgPlan(
                        2,
                        annotation_text(
                            annotation, "name", parameter.name()),
                        shown)
                    bound.value_kind = scalar_kind(type_name)
                    if bound.value_kind < 0 {
                        return err(
                            "@query parameter {parameter.name()} must be int, float, bool or string",
                            "binding")
                    }
                    let fallback: string = annotation_text(
                        annotation, "default", "")
                    if fallback != "" {
                        bound.fallback = fallback
                        bound.has_fallback = true
                    } else if !annotation_flag(
                                  annotation, "required", true) {
                        bound.fallback = ""
                        bound.has_fallback = true
                    }
                    plan.arguments.push(bound)
                } else if marker_name == "espresso.header" {
                    let bound: ArgPlan = new ArgPlan(
                        3,
                        annotation_text(
                            annotation, "name",
                            header_name(parameter.name())),
                        shown)
                    if type_name != "string" {
                        return err(
                            "@header parameter {parameter.name()} must be a string",
                            "binding")
                    }
                    bound.value_kind = 3
                    bound.required = annotation_flag(
                        annotation, "required", false)
                    plan.arguments.push(bound)
                } else if marker_name == "espresso.body" {
                    if parameter.passing() != reflect.Passing.taken {
                        return err(
                            "@body parameter {parameter.name()} must be a move parameter",
                            "binding")
                    }
                    let bound: ArgPlan = new ArgPlan(4, "", shown)
                    bound.body_plan = binder.plan_for(parameter_type)?
                    plan.arguments.push(bound)
                } else {
                    let bound: ArgPlan = new ArgPlan(5, "", shown)
                    bound.service = some(parameter_type)
                    plan.arguments.push(bound)
                }
            }
        }
    }

    // Filters: the action's own annotations win over the controller's.
    var filters: List<reflect.Annotation> = []
    for annotation: reflect.Annotation in controller_filters {
        filters.push(annotation)
    }
    for annotation: reflect.Annotation in action.annotations() {
        filters.push(annotation)
    }
    for annotation: reflect.Annotation in filters {
        let name: string = annotation.qualified_name()
        if name == "espresso.auth" {
            plan.has_auth = true
            plan.auth_policy = annotation_text(annotation, "policy", "")
        } else if name == "espresso.validate" {
            plan.validate_body = true
        } else if name == "espresso.limit" {
            plan.limit_rpm = annotation_number(annotation, "rpm", 60)
            if plan.limit_rpm <= 0 {
                return err(
                    "@limit rpm must be positive on {action.name()}",
                    "binding")
            }
        }
    }
    if plan.validate_body {
        var validated: bool = false
        for argument: ArgPlan in plan.arguments {
            if argument.kind == 4 &&
               binder.has_validator(argument.body_plan) {
                validated = true
            }
        }
        if !validated {
            return err(
                "@validate on {action.name()} needs a @body parameter whose type declares validate(errors: ValidationErrors)",
                "binding")
        }
    }
    match marker {
        some(_) => {}
        none => {}
    }
    return ok(plan)
}
