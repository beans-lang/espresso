package espresso

import std.encoding.json

fn openapi_operation_id(route: Route) -> string {
    var name: string = route.pattern
        .replace("/", "_")
        .replace("\{", "")
        .replace("\}", "")
        .replace("*", "all_")
    for name.starts_with("_") {
        name = name.slice(1, name.len())
    }
    if name == "" { name = "root" }
    return "{route.method.to_lower()}_{name}"
}

fn openapi_operation(route: Route) -> Result<json.Value> {
    let operation: json.Value = json.Value.object()
    operation.add("operationId", json.Value.from_string(
        openapi_operation_id(route)))?
    let parameters: json.Value = json.Value.array()
    for index: int in 0..route.kinds.len() {
        if route.kinds[index] == 0 { continue }
        let parameter: json.Value = json.Value.object()
        parameter.add("name", json.Value.from_string(route.names[index]))?
        parameter.add("in", json.Value.from_string("path"))?
        parameter.add("required", json.Value.from_bool(true))?
        let schema: json.Value = json.Value.object()
        schema.add("type", json.Value.from_string("string"))?
        parameter.add("schema", schema)?
        parameters.push(parameter)?
    }
    if parameters.len()? != 0 { operation.add("parameters", parameters)? }
    let response: json.Value = json.Value.object()
    response.add("description", json.Value.from_string("Successful response"))?
    let responses: json.Value = json.Value.object()
    responses.add("200", response)?
    operation.add("responses", responses)?
    return ok(operation)
}

fn router_openapi(router: Router,
                  title: string,
                  version: string) -> Result<string> {
    let document: json.Value = json.Value.object()
    document.add("openapi", json.Value.from_string("3.1.0"))?
    let info: json.Value = json.Value.object()
    info.add("title", json.Value.from_string(title))?
    info.add("version", json.Value.from_string(version))?
    document.add("info", info)?
    let paths: json.Value = json.Value.object()
    for route: Route in router.routes {
        var path_item: json.Value = json.Value.object()
        match paths.get(route.pattern) {
            some(found) => { path_item = found }
            none => { paths.add(route.pattern, path_item)? }
        }
        // Read it back after insertion because Value.add deep-copies into the
        // destination document.
        let target: json.Value = paths.get(route.pattern).or(path_item)
        target.add(route.method.to_lower(), openapi_operation(route)?)?
    }
    document.add("paths", paths)?
    return json.stringify(document)
}

/// Generates the current route table as OpenAPI 3.1 JSON.
pub fn openapi_json(app: WebApplication,
                    title: string,
                    version: string) -> Result<string> {
    return router_openapi(app.router, title, version)
}

/// Adds a GET endpoint that serves a snapshot of the current route table.
pub fn map_openapi(app: WebApplication,
                   path: string = "/openapi.json",
                   title: string = "Espresso API",
                   version: string = "1.0.0") -> Result<bool> {
    let document: string = openapi_json(app, title, version)?
    return app.get(path, fn(context: HttpContext) -> Result<ActionResult> {
        return json_text(document)
    })
}
