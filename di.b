package espresso

import std.reflect

/// Lifetime of a dependency registered in Espresso's service container.
pub enum ServiceLifetime {
    transient
    scoped
    singleton
}

/// Marks a class for add_services discovery. The class registers as
/// itself and as each interface it directly implements, under the given
/// lifetime. Discovery is opt-in sugar over explicit registration —
/// the composition root stays the place to look when it matters.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation service {
    lifetime: ServiceLifetime = ServiceLifetime.scoped
}

class ServiceDescriptor {
    service_type: reflect.Type
    implementation_type: reflect.Type
    lifetime: ServiceLifetime
    factory: fn(ServiceProvider) -> Result<reflect.Value>

    fn init(service_type: reflect.Type,
            implementation_type: reflect.Type,
            lifetime: ServiceLifetime,
            factory: fn(ServiceProvider) -> Result<reflect.Value>) {
        self.service_type = service_type
        self.implementation_type = implementation_type
        self.lifetime = lifetime
        self.factory = factory
    }
}

class ServiceRegistry {
    descriptors: List<ServiceDescriptor> = []

    fn add(descriptor: ServiceDescriptor) {
        self.descriptors.push(descriptor)
    }

    fn find(name: string) -> Option<ServiceDescriptor> {
        var index: int = self.descriptors.len()
        for index > 0 {
            index -= 1
            let descriptor: ServiceDescriptor = self.descriptors[index]
            if descriptor.service_type.qualified_name() == name {
                return some(descriptor)
            }
        }
        return none
    }
}

class SingletonStore {
    values: Map<string, reflect.Value> = {}
    creation_order: List<string> = []

    fn put(name: string, value: reflect.Value) {
        if !self.values.contains_key(name) {
            self.creation_order.push(name)
        }
        self.values[name] = value
    }

    fn close() {
        var index: int = self.creation_order.len()
        for index > 0 {
            index -= 1
            self.values.remove(self.creation_order[index])
        }
        self.creation_order.clear()
    }
}

/// Registrations collected while an Espresso application is built.
pub class ServiceCollection {
    registry: ServiceRegistry = new ServiceRegistry()
    built: bool = false

    pub fn init() {}

    fn add_descriptor(descriptor: ServiceDescriptor) -> Result<bool> {
        if self.built {
            return err("services cannot be changed after the provider is built", "services_built")
        }
        if !descriptor.service_type.is_assignable_from(
                descriptor.implementation_type) {
            return err(
                "{descriptor.implementation_type.qualified_name()} cannot be used as {descriptor.service_type.qualified_name()}",
                "service_type")
        }
        self.registry.add(descriptor)
        return ok(true)
    }

    /// Registers a concrete implementation for a service type. Constructor
    /// parameters are resolved from the same provider when the service is made.
    pub fn add(service_type: reflect.Type,
               implementation_type: reflect.Type,
               lifetime: ServiceLifetime) -> Result<bool> {
        let factory: fn(ServiceProvider) -> Result<reflect.Value> =
            fn(provider: ServiceProvider) -> Result<reflect.Value> {
                return provider.activate(implementation_type)
            }
        return self.add_descriptor(new ServiceDescriptor(
            service_type, implementation_type, lifetime, factory))
    }

    /// Registers I as the implementation of S:
    /// `services.add_transient<Clock, SystemClock>()`. The runtime-typed
    /// `add` stays as the escape hatch for types only known at runtime —
    /// which is what the controller scanner itself uses.
    pub fn add_transient<S, I>() -> Result<bool> {
        return self.add(type_of(S), type_of(I),
                        ServiceLifetime.transient)
    }

    pub fn add_scoped<S, I>() -> Result<bool> {
        return self.add(type_of(S), type_of(I),
                        ServiceLifetime.scoped)
    }

    pub fn add_singleton<S, I>() -> Result<bool> {
        return self.add(type_of(S), type_of(I),
                        ServiceLifetime.singleton)
    }

    /// Registers a concrete type as itself:
    /// `services.transient<Greeter>()`.
    pub fn transient<T>() -> Result<bool> {
        return self.add(type_of(T), type_of(T),
                        ServiceLifetime.transient)
    }

    pub fn scoped<T>() -> Result<bool> {
        return self.add(type_of(T), type_of(T),
                        ServiceLifetime.scoped)
    }

    pub fn singleton<T>() -> Result<bool> {
        return self.add(type_of(T), type_of(T),
                        ServiceLifetime.singleton)
    }

    /// Freezes registrations and creates the root provider.
    pub fn build_provider(validate_scopes: bool = true) -> ServiceProvider {
        self.built = true
        return new ServiceProvider(
            self.registry, new SingletonStore(), true, validate_scopes)
    }
}

/// One dependency-injection scope. Create one child scope per HTTP request.
pub class ServiceProvider {
    registry: ServiceRegistry
    singletons: SingletonStore
    scoped_values: Map<string, reflect.Value> = {}
    scoped_order: List<string> = []
    resolving: List<string> = []
    root: bool
    validate_scopes: bool
    singleton_depth: int = 0
    closed: bool = false

    fn init(registry: ServiceRegistry,
            singletons: SingletonStore,
            root: bool,
            validate_scopes: bool) {
        self.registry = registry
        self.singletons = singletons
        self.root = root
        self.validate_scopes = validate_scopes
    }

    pub fn create_scope() -> Result<ServiceProvider> {
        if self.closed { return err("the service provider is closed", "closed") }
        return ok(new ServiceProvider(
            self.registry, self.singletons, false, self.validate_scopes))
    }

    fn has_registrations() -> bool {
        return self.registry.descriptors.len() != 0
    }

    fn close_scope() -> Result<bool> {
        if self.root { return ok(true) }
        return self.close()
    }

    fn resolving_contains(name: string) -> bool {
        for active: string in self.resolving {
            if active == name { return true }
        }
        return false
    }

    fn cache_scoped(name: string, value: reflect.Value) {
        if !self.scoped_values.contains_key(name) {
            self.scoped_order.push(name)
        }
        self.scoped_values[name] = value
    }

    fn descriptor(name: string) -> Result<ServiceDescriptor> {
        match self.registry.find(name) {
            some(found) => { return ok(found) }
            none => {
                return err("service {name} is not registered", "service_missing")
            }
        }
    }

    fn initializer(implementation: reflect.Type) -> Result<reflect.Initializer> {
        match implementation.initializer() {
            some(found) => { return ok(found) }
            none => {
                return err(
                    "service {implementation.qualified_name()} has no initializer",
                    "service_constructor")
            }
        }
    }

    fn resolve_value(service_type: reflect.Type) -> Result<reflect.Value> {
        if self.closed { return err("the service provider is closed", "closed") }
        let name: string = service_type.qualified_name()
        let descriptor: ServiceDescriptor = self.descriptor(name)?

        match descriptor.lifetime {
            singleton => {
                match self.singletons.values.get(name) {
                    some(value) => { return ok(value) }
                    none => {}
                }
            }
            scoped => {
                if self.root && self.validate_scopes {
                    return err("scoped service {name} cannot be resolved from the root provider", "scope")
                }
                if self.singleton_depth > 0 && self.validate_scopes {
                    return err("singleton service cannot capture scoped service {name}", "scope")
                }
                match self.scoped_values.get(name) {
                    some(value) => { return ok(value) }
                    none => {}
                }
            }
            transient => {}
        }

        if self.resolving_contains(name) {
            return err("dependency cycle while resolving {name}", "service_cycle")
        }

        self.resolving.push(name)
        if descriptor.lifetime == ServiceLifetime.singleton {
            self.singleton_depth += 1
        }
        let made: Result<reflect.Value> = descriptor.factory(self)
        if descriptor.lifetime == ServiceLifetime.singleton {
            self.singleton_depth -= 1
        }
        self.resolving.remove(self.resolving.len() - 1)

        let value: reflect.Value = made?
        match descriptor.lifetime {
            singleton => { self.singletons.put(name, value) }
            scoped => { self.cache_scoped(name, value) }
            transient => {}
        }
        return ok(value)
    }

    fn activate(implementation: reflect.Type) -> Result<reflect.Value> {
        let initializer: reflect.Initializer = self.initializer(implementation)?
        if !initializer.is_public() {
            return err(
                "service {implementation.qualified_name()} initializer is not public",
                "service_constructor")
        }
        var arguments: List<reflect.Value> = []
        for parameter: reflect.Parameter in initializer.parameters() {
            if parameter.passing() != reflect.Passing.borrowed {
                return err(
                    "service constructor parameter {parameter.name()} must be borrowed",
                    "service_constructor")
            }
            arguments.push(self.resolve_value(parameter.type())?)
        }
        match initializer.call(move arguments) {
            ok(value) => { return ok(value) }
            err(problem) => {
                return err(
                    "cannot construct {implementation.qualified_name()}: {problem.message()}",
                    "service_constructor")
            }
        }
    }

    /// Resolves one service by its registered type:
    /// `let store: Store = context.services.resolve<Store>()?`.
    pub fn resolve<T>() -> Result<T> {
        let boxed: reflect.Value = self.resolve_value(type_of(T))?
        match boxed as? T {
            some(value) => { return ok(value) }
            none => {
                return err(
                    "registered service cannot be converted to {type_of(T).qualified_name()}",
                    "service_type")
            }
        }
    }

    /// Releases scoped services in reverse creation order. Closing the root
    /// provider also releases singleton services in reverse creation order.
    pub fn close() -> Result<bool> {
        if self.closed { return err("the service provider is closed", "closed") }
        var index: int = self.scoped_order.len()
        for index > 0 {
            index -= 1
            self.scoped_values.remove(self.scoped_order[index])
        }
        self.scoped_order.clear()
        if self.root { self.singletons.close() }
        self.closed = true
        return ok(true)
    }
}

/// Registers a factory. T is inferred from the factory's declared result type.
pub fn add_factory<T>(services: ServiceCollection,
                      lifetime: ServiceLifetime,
                      factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    let service_type: reflect.Type = type_of(T)
    let erased: fn(ServiceProvider) -> Result<reflect.Value> =
        fn(provider: ServiceProvider) -> Result<reflect.Value> {
            let made: T = factory(provider)?
            return ok(reflect.value(move made))
        }
    return services.add_descriptor(new ServiceDescriptor(
        service_type, service_type, lifetime, erased))
}

pub fn add_transient_factory<T>(services: ServiceCollection,
                                factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    return add_factory(services, ServiceLifetime.transient, factory)
}

pub fn add_scoped_factory<T>(services: ServiceCollection,
                             factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    return add_factory(services, ServiceLifetime.scoped, factory)
}

pub fn add_singleton_factory<T>(services: ServiceCollection,
                                factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    return add_factory(services, ServiceLifetime.singleton, factory)
}

fn scanned_service_annotation(
    type: reflect.Type) -> Option<reflect.Annotation> {
    for annotation: reflect.Annotation in type.annotations() {
        if annotation.qualified_name() == "espresso.service" {
            return some(annotation)
        }
    }
    return none
}

fn scanned_service_lifetime(
    annotation: reflect.Annotation) -> Result<ServiceLifetime> {
    match annotation.argument("lifetime") {
        some(argument) => {
            let name: string = argument.value().text()
            if name == "transient" {
                return ok(ServiceLifetime.transient)
            }
            if name == "scoped" { return ok(ServiceLifetime.scoped) }
            if name == "singleton" {
                return ok(ServiceLifetime.singleton)
            }
            return err("unknown service lifetime '{name}'", "service")
        }
        none => { return ok(ServiceLifetime.scoped) }
    }
}

/// Registers every linked @service class: as itself, and as each
/// interface it directly implements, forwarded so one scope shares one
/// instance across all of its names. Two @service classes claiming the
/// same service type is an error here, not a silent override — drop
/// @service from one and register your choice explicitly. Call before
/// build, like add_controllers.
pub fn add_services(builder: WebApplicationBuilder) -> Result<int> {
    var count: int = 0
    var claimed: Map<string, string> = {}
    for type: reflect.Type in reflect.types() {
        match scanned_service_annotation(type) {
            none => {}
            some(marker) => {
                let shown: string = type.qualified_name()
                if type.kind() != reflect.Kind.class_type {
                    return err(
                        "@service can only mark a class, got {shown}",
                        "service")
                }
                if controller_annotation(type).is_some() {
                    return err(
                        "{shown} is a @controller, which is already a scoped service — drop its @service",
                        "service")
                }
                if type.initializer().is_none() {
                    return err(
                        "@service class {shown} has no public initializer the container can call — a `singleton class` or a hand-built value registers through a factory (add_singleton_factory) instead",
                        "service")
                }
                let lifetime: ServiceLifetime =
                    scanned_service_lifetime(marker)?
                var surfaces: List<reflect.Type> = [type]
                for implemented: reflect.Type in type.interfaces() {
                    surfaces.push(implemented)
                }
                for surface: reflect.Type in surfaces {
                    let name: string = surface.qualified_name()
                    match claimed.get(name) {
                        some(owner) => {
                            return err(
                                "service {name} is provided by both {owner} and {shown} — drop @service from one and register your choice explicitly",
                                "service_conflict")
                        }
                        none => {}
                    }
                    claimed[name] = shown
                    if name == shown {
                        builder.services.add(surface, type, lifetime)?
                    } else {
                        // Interface names forward to the concrete
                        // registration, so a scope resolves the same
                        // instance under every name.
                        let concrete: reflect.Type = type
                        builder.services.add_descriptor(
                            new ServiceDescriptor(
                                surface, type, lifetime,
                                fn(provider: ServiceProvider) ->
                                    Result<reflect.Value> {
                                    return provider.resolve_value(
                                        concrete)
                                }))?
                    }
                }
                count += 1
            }
        }
    }
    return ok(count)
}
