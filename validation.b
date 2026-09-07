package espresso

import std.encoding.json

pub class ValidationError {
    pub field: string
    pub message: string
    pub code: string

    pub fn init(field: string, message: string, code: string) {
        self.field = field
        self.message = message
        self.code = code
    }
}

/// Explicit validation errors for request DTOs and route/query values.
pub class ValidationErrors {
    errors: List<ValidationError> = []

    pub fn init() {}

    pub fn add(field: string, message: string,
               code: string = "invalid") {
        self.errors.push(new ValidationError(field, message, code))
    }

    pub fn required(field: string, value: string) {
        if value.trim() == "" {
            self.add(field, "{field} is required", "required")
        }
    }

    pub fn length(field: string, value: string,
                  minimum: int, maximum: int) {
        if value.len() < minimum || value.len() > maximum {
            self.add(
                field,
                "{field} must contain {minimum}..{maximum} bytes",
                "length")
        }
    }

    pub fn integer_range(field: string, value: int,
                         minimum: int, maximum: int) {
        if value < minimum || value > maximum {
            self.add(
                field,
                "{field} must be between {minimum} and {maximum}",
                "range")
        }
    }

    pub fn count() -> int { return self.errors.len() }
    pub fn is_valid() -> bool { return self.errors.len() == 0 }
    pub fn at(index: int) -> ValidationError { return self.errors[index] }
}

/// Writes an RFC 9457-style validation problem.
pub fn write_validation_problem(context: HttpContext,
                                errors: ValidationErrors) -> Result<bool> {
    let problem: json.Value = json.Value.object()
    problem.add("status", json.Value.from_int(400))?
    problem.add("title", json.Value.from_string("Validation Failed"))?
    problem.add("traceId", json.Value.from_string(context.trace_id()))?
    let items: json.Value = json.Value.array()
    for index: int in 0..errors.count() {
        let error: ValidationError = errors.at(index)
        let item: json.Value = json.Value.object()
        item.add("field", json.Value.from_string(error.field))?
        item.add("message", json.Value.from_string(error.message))?
        item.add("code", json.Value.from_string(error.code))?
        items.push(item)?
    }
    problem.add("errors", items)?
    // The problem document goes over as the string json.stringify just built.
    // Bytes.from(...) copied it into a buffer for no reason: `bytes` wants a
    // payload it can own, and this one is already owned by nobody else, so the
    // copy bought nothing. text_body holds the string by reference, which is
    // also what ProblemResult does with the identical document — the two paths
    // now frame the same body the same way.
    context.response.text_body(
        400, "Bad Request", json.stringify(problem)?,
        "application/problem+json; charset=utf-8")
    return ok(true)
}
