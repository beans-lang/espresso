package espresso

import std.os

/// Layered string configuration. Later sources replace earlier values.
pub class Configuration {
    values: Map<string, string> = {}

    pub fn init() {}

    fn key(name: string) -> string {
        return name.trim().to_lower()
    }

    pub fn set(name: string, value: string) -> Result<bool> {
        let normalized: string = self.key(name)
        if normalized == "" { return err("configuration key is empty", "config") }
        self.values[normalized] = value
        return ok(true)
    }

    pub fn get(name: string) -> Option<string> {
        return self.values.get(self.key(name))
    }

    pub fn require(name: string) -> Result<string> {
        match self.get(name) {
            some(value) => { return ok(value) }
            none => { return err("missing configuration value {name}", "config") }
        }
    }

    pub fn integer(name: string, fallback: int) -> Result<int> {
        match self.get(name) {
            some(value) => {
                match value.to_int() {
                    ok(parsed) => { return ok(parsed) }
                    err(_) => {
                        return err("configuration value {name} must be an integer", "config")
                    }
                }
            }
            none => { return ok(fallback) }
        }
    }

    pub fn boolean(name: string, fallback: bool) -> Result<bool> {
        match self.get(name) {
            some(value) => {
                let normalized: string = value.trim().to_lower()
                if normalized == "true" || normalized == "1" ||
                   normalized == "yes" || normalized == "on" {
                    return ok(true)
                }
                if normalized == "false" || normalized == "0" ||
                   normalized == "no" || normalized == "off" {
                    return ok(false)
                }
                return err("configuration value {name} must be a boolean", "config")
            }
            none => { return ok(fallback) }
        }
    }

    /// Reads a known set of environment variables. `__` maps to `:`.
    pub fn add_environment(names: List<string>,
                           prefix: string = "ESPRESSO_") -> Result<bool> {
        for name: string in names {
            let environment_name: string =
                "{prefix}{name.to_upper().replace(":", "__")}"
            match os.env(environment_name) {
                some(value) => { self.set(name, value)? }
                none => {}
            }
        }
        return ok(true)
    }

    /// Reads `--key=value` and `--key value` arguments.
    pub fn add_arguments(arguments: List<string>) -> Result<bool> {
        var index: int = 0
        for index < arguments.len() {
            let argument: string = arguments[index]
            if !argument.starts_with("--") {
                index += 1
                continue
            }
            let option: string = argument.slice(2, argument.len())
            match option.find("=") {
                some(at) => {
                    self.set(option.slice(0, at),
                             option.slice(at + 1, option.len()))?
                }
                none => {
                    if index + 1 >= arguments.len() ||
                       arguments[index + 1].starts_with("--") {
                        return err("argument --{option} needs a value", "config")
                    }
                    self.set(option, arguments[index + 1])?
                    index += 1
                }
            }
            index += 1
        }
        return ok(true)
    }
}

/// Applies the standard `server:*` keys to server options.
pub fn configure_server(config: Configuration,
                        options: ServerOptions) -> Result<bool> {
    options.host = config.get("server:host").or(options.host)
    options.port = config.integer("server:port", options.port)?
    options.backlog = config.integer("server:backlog", options.backlog)?
    options.max_connections = config.integer(
        "server:max-connections", options.max_connections)?
    options.idle_timeout_ms = config.integer(
        "server:idle-timeout-ms", options.idle_timeout_ms)?
    options.graceful_shutdown_ms = config.integer(
        "server:graceful-shutdown-ms", options.graceful_shutdown_ms)?
    options.max_body_bytes = config.integer(
        "server:max-body-bytes", options.max_body_bytes)?
    return options.validate()
}
