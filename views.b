// Server-side views.
//
// A ViewResult is one more ActionResult — nothing in the pipeline changed
// to accept it, which is the whole reason ActionResult is an interface.
// Templates compile once when added; rendering walks the compiled tree
// against the model. The model arrives typed at the call site —
// `self.view("order", order)` — and is carried through its JSON encoding,
// so anything std.encoding.json can encode can be rendered.
//
// Template language, deliberately small:
//   {{name}}        insert, HTML-escaped; dotted paths descend objects
//   {{{name}}}      insert raw
//   {{#name}}...{{/name}}   for an array: repeat per element; for an
//                           object: descend; for true: render once
//   {{^name}}...{{/name}}   render when missing, false, or empty
//   {{.}}           the current scalar inside an array section
package espresso

import github.com/beans-lang/barista

import std.encoding.json
import std.reflect

// A compiled template node. kind: 0 text, 1 insert, 2 raw insert,
// 3 section, 4 inverted section.
class ViewNode {
    kind: int
    text: string
    path: List<string> = []
    children: List<ViewNode> = []

    fn init(kind: int, text: string) {
        self.kind = kind
        self.text = text
    }
}

class ViewTemplate {
    name: string
    nodes: List<ViewNode> = []

    fn init(name: string) { self.name = name }
}

fn find_text_from(source: string, needle: string, start: int) -> int {
    if needle.len() == 0 { return -1 }
    var index: int = start
    for index + needle.len() <= source.len() {
        if source.range_equals(index, index + needle.len(), needle) {
            return index
        }
        index += 1
    }
    return -1
}

fn split_view_path(raw: string) -> List<string> {
    if raw == "." { return [] }
    return raw.split(".")
}

fn html_escape_into(target: Bytes, text: string) {
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        if byte == 38 { target.append_string("&amp;") }
        else if byte == 60 { target.append_string("&lt;") }
        else if byte == 62 { target.append_string("&gt;") }
        else if byte == 34 { target.append_string("&quot;") }
        else if byte == 39 { target.append_string("&#39;") }
        else { target.push(byte) }
    }
}

// One frame of the render stack: the current model node.
fn view_lookup(stack: List<json.Value>,
               path: List<string>) -> Option<json.Value> {
    if path.len() == 0 {
        if stack.len() == 0 { return none }
        return some(stack[stack.len() - 1])
    }
    // The nearest frame that has the first segment wins, like mustache.
    var frame: int = stack.len()
    for frame > 0 {
        frame -= 1
        var current: json.Value = stack[frame]
        match current.get(path[0]) {
            some(found) => {
                current = found
                var index: int = 1
                for index < path.len() {
                    match current.get(path[index]) {
                        some(child) => { current = child }
                        none => { return none }
                    }
                    index += 1
                }
                return some(current)
            }
            none => {}
        }
    }
    return none
}

fn view_scalar_text(node: json.Value) -> string {
    let kind: json.Kind = node.kind()
    if kind == json.Kind.text { return node.to_string().or("") }
    if kind == json.Kind.integer ||
       kind == json.Kind.unsigned_integer {
        return "{node.to_int().or(0)}"
    }
    if kind == json.Kind.floating { return "{node.number().or(0.0)}" }
    if kind == json.Kind.boolean {
        return if node.to_bool().or(false) { "true" } else { "false" }
    }
    return ""
}

fn view_truthy(node: json.Value) -> bool {
    let kind: json.Kind = node.kind()
    if kind == json.Kind.null { return false }
    if kind == json.Kind.boolean { return node.to_bool().or(false) }
    if kind == json.Kind.array { return node.len().or(0) != 0 }
    return true
}

/// Compiled templates by name. Register the collection as a singleton
/// with add_views; ViewResult resolves it from the request scope.
pub class Views {
    templates: Map<string, ViewTemplate> = {}

    pub fn init() {}

    /// Compiles and stores one template. Recompiling a name replaces it.
    pub fn add(name: string, source: string) -> Result<bool> {
        let template: ViewTemplate = new ViewTemplate(name)
        var stack: List<ViewNode> = []
        var open_sections: List<ViewNode> = []
        var cursor: int = 0
        var text_start: int = 0
        for cursor < source.len() {
            if cursor + 1 < source.len() &&
               source.byte_at(cursor) == 123 &&
               source.byte_at(cursor + 1) == 123 {
                if cursor > text_start {
                    self.push_node(
                        template, open_sections,
                        new ViewNode(
                            0, source.slice(text_start, cursor)))
                }
                let raw: bool = cursor + 2 < source.len() &&
                                source.byte_at(cursor + 2) == 123
                let open: int = cursor + (if raw { 3 } else { 2 })
                let closer: string = if raw { "\}\}\}" } else { "\}\}" }
                let close: int = find_text_from(source, closer, open)
                if close < 0 {
                    return err(
                        "view {name}: unclosed tag at byte {cursor}",
                        "view")
                }
                let inner: string = source.slice(open, close).trim()
                if inner == "" {
                    return err("view {name}: empty tag", "view")
                }
                cursor = close + closer.len()
                text_start = cursor
                if raw {
                    let node: ViewNode = new ViewNode(2, inner)
                    node.path = split_view_path(inner)
                    self.push_node(template, open_sections, node)
                    continue
                }
                let head: int = inner.byte_at(0)
                if head == 35 || head == 94 {
                    let node: ViewNode = new ViewNode(
                        if head == 35 { 3 } else { 4 },
                        inner.slice(1, inner.len()).trim())
                    node.path = split_view_path(node.text)
                    self.push_node(template, open_sections, node)
                    open_sections.push(node)
                    continue
                }
                if head == 47 {
                    let closing: string =
                        inner.slice(1, inner.len()).trim()
                    if open_sections.len() == 0 {
                        return err(
                            "view {name}: close tag '{closing}' matches no open section",
                            "view")
                    }
                    let last: ViewNode =
                        open_sections[open_sections.len() - 1]
                    if last.text != closing {
                        return err(
                            "view {name}: section '{last.text}' is closed as '{closing}'",
                            "view")
                    }
                    open_sections.remove(open_sections.len() - 1)
                    continue
                }
                let node: ViewNode = new ViewNode(1, inner)
                node.path = split_view_path(inner)
                self.push_node(template, open_sections, node)
                continue
            }
            cursor += 1
        }
        if open_sections.len() != 0 {
            return err(
                "view {name}: section '{open_sections[open_sections.len() - 1].text}' is never closed",
                "view")
        }
        if text_start < source.len() {
            self.push_node(
                template, open_sections,
                new ViewNode(0, source.slice(text_start, source.len())))
        }
        self.templates[name] = template
        return ok(true)
    }

    fn push_node(template: ViewTemplate,
                 open_sections: List<ViewNode>,
                 node: ViewNode) {
        if open_sections.len() != 0 {
            open_sections[open_sections.len() - 1].children.push(node)
        } else {
            template.nodes.push(node)
        }
    }

    pub fn has(name: string) -> bool {
        return self.templates.contains_key(name)
    }

    /// Renders one template against an encoded model.
    pub fn render(name: string, model: json.Value) -> Result<string> {
        var template: Option<ViewTemplate> = none
        match self.templates.get(name) {
            some(found) => { template = some(found) }
            none => {
                return err("view {name} is not registered", "view")
            }
        }
        let target: Bytes = new Bytes(0)
        var stack: List<json.Value> = [model]
        self.render_nodes(
            template.expect("template").nodes, stack, target)?
        return ok(target.to_string())
    }

    fn render_nodes(nodes: List<ViewNode>,
                    stack: List<json.Value>,
                    target: Bytes) -> Result<bool> {
        for node: ViewNode in nodes {
            if node.kind == 0 {
                target.append_string(node.text)
            } else if node.kind == 1 || node.kind == 2 {
                match view_lookup(stack, node.path) {
                    some(found) => {
                        let text: string = view_scalar_text(found)
                        if node.kind == 2 {
                            target.append_string(text)
                        } else {
                            html_escape_into(target, text)
                        }
                    }
                    none => {}
                }
            } else if node.kind == 3 {
                match view_lookup(stack, node.path) {
                    some(found) => {
                        if found.kind() == json.Kind.array {
                            for element: json.Value in
                                found.elements()? {
                                stack.push(element)
                                self.render_nodes(
                                    node.children, stack, target)?
                                stack.remove(stack.len() - 1)
                            }
                        } else if view_truthy(found) {
                            stack.push(found)
                            self.render_nodes(
                                node.children, stack, target)?
                            stack.remove(stack.len() - 1)
                        }
                    }
                    none => {}
                }
            } else {
                var render_inverted: bool = true
                match view_lookup(stack, node.path) {
                    some(found) => {
                        render_inverted = !view_truthy(found)
                    }
                    none => {}
                }
                if render_inverted {
                    self.render_nodes(node.children, stack, target)?
                }
            }
        }
        return ok(true)
    }
}

/// Registers a compiled view collection as the app's singleton Views.
pub fn add_views(builder: WebApplicationBuilder,
                 views: Views) -> Result<bool> {
    return barista.add_singleton_factory<Views>(
        builder.services,
        fn(provider: barista.ServiceProvider) -> Result<Views> {
            return ok(views)
        })
}

/// Renders a registered template with the model when it executes.
pub class ViewResult implements ActionResult {
    status: int
    name: string
    model: json.Value

    pub fn init(status: int, name: string, model: json.Value) {
        self.status = status
        self.name = name
        self.model = model
    }

    pub fn execute(context: HttpContext) -> Result<bool> {
        var views: Option<reflect.Value> = none
        match context.services.resolve_type(type_of(Views)) {
            ok(value) => { views = some(value) }
            err(_) => {
                let missing: ProblemResult = new ProblemResult(
                    500, "Internal Server Error",
                    "views need add_views(builder, views) at startup")
                return missing.execute(context)
            }
        }
        match views.expect("views") as? Views {
            some(collection) => {
                match collection.render(self.name, self.model) {
                    ok(rendered) => {
                        context.response.text_body(
                            self.status, reason_for(self.status),
                            rendered, "text/html; charset=utf-8")
                        return ok(true)
                    }
                    err(problem) => {
                        let failed: ProblemResult = new ProblemResult(
                            500, "Internal Server Error", problem.msg)
                        return failed.execute(context)
                    }
                }
            }
            none => {
                let wrong: ProblemResult = new ProblemResult(
                    500, "Internal Server Error",
                    "the registered Views service has the wrong type")
                return wrong.execute(context)
            }
        }
    }
}

/// A 200 text/html view over a typed model. The model is checked at the
/// call site: anything json.encode accepts renders.
pub fn view<T>(name: string, move model: T) -> Result<ActionResult> {
    let encoded: string = json.encode(move model)?
    return ok(new ViewResult(200, name, json.parse(encoded)?))
}

/// A view over a JSON DOM model built by hand.
pub fn view_model(name: string,
                  model: json.Value) -> Result<ActionResult> {
    return ok(new ViewResult(200, name, model))
}
