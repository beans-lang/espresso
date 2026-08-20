package espresso

import std.reflect

/// Lifetime of a dependency registered in Espresso's service container.
pub enum ServiceLifetime {
    transient
    scoped
    singleton
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

    pub fn add_transient(service_type: reflect.Type,
                         implementation_type: reflect.Type) -> Result<bool> {
        return self.add(service_type, implementation_type,
                        ServiceLifetime.transient)
    }

    pub fn add_scoped(service_type: reflect.Type,
                      implementation_type: reflect.Type) -> Result<bool> {
        return self.add(service_type, implementation_type,
                        ServiceLifetime.scoped)
    }

    pub fn add_singleton(service_type: reflect.Type,
                         implementation_type: reflect.Type) -> Result<bool> {
        return self.add(service_type, implementation_type,
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

/// A type witness for resolving one service. Beans does not infer a generic
/// argument from a function's result, so this small value carries T explicitly.
pub class ServiceKey<T> {
    pub fn init() {}

    pub fn resolve(provider: ServiceProvider) -> Result<T> {
        let boxed: reflect.Value = provider.resolve_value(type_of(T))?
        match boxed as? T {
            some(value) => { return ok(value) }
            none => {
                return err(
                    "registered service cannot be converted to {type_of(T).qualified_name()}",
                    "service_type")
            }
        }
    }
}

pub fn service<T>(provider: ServiceProvider, key: ServiceKey<T>) -> Result<T> {
    return key.resolve(provider)
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
