// What is left of espresso's container: the one function that knew about a
// `WebApplicationBuilder`.
//
// Everything else — `ServiceCollection`, `ServiceProvider`, the three
// lifetimes, constructor injection, `Disposable`, the `@service` scan — is the
// `barista` package. Espresso's public names for those are gone rather than
// aliased: two names for one type is two things to keep in step, and a shim
// would have to be maintained for as long as anyone believed it.
//
//     - espresso.ServiceCollection      + barista.ServiceCollection
//     - espresso.ServiceProvider        + barista.ServiceProvider
//     - espresso.ServiceLifetime        + barista.ServiceLifetime
//     - @espresso.service               + @barista.service
//     - espresso.add_singleton_factory  + barista.add_singleton_factory
//
// `espresso.add_services(builder)` stays, because it does something barista
// cannot: it refuses `@service` on a `@controller`.
package espresso

import barista
import std.reflect

/// Registers every linked `@barista.service` class into this builder.
///
/// The scan itself is barista's. What espresso adds is one refusal: a
/// `@controller` is already registered as a scoped service by
/// `add_controllers`, so `@service` on one would register it twice — under the
/// same name, with whatever lifetime the annotation asked for, silently
/// replacing the other. barista knows nothing about controllers, which is why
/// it takes the veto as a closure rather than growing a category.
///
/// Call before `build`, like `add_controllers`.
pub fn add_services(builder: WebApplicationBuilder) -> Result<int> {
    return barista.add_services_except(
        builder.services,
        fn(type: reflect.Type) -> Option<string> {
            if controller_annotation(type).is_some() {
                return some(
                    "{type.qualified_name()} is a @controller, which is already a scoped service — drop its @service")
            }
            return none
        })
}
