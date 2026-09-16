// What is left of espresso's container: the one function that knew about a
// `WebApplicationBuilder`. Everything else — `ServiceCollection`,
// `ServiceProvider`, the lifetimes, constructor injection, `Disposable`, the
// `@service` scan — is the `barista` package now; espresso's own names for
// those are gone, not aliased (see CHANGELOG.md for the rename table).
//
// `espresso.add_services(builder)` stays, because it does something barista
// cannot: it refuses `@service` on a `@controller`.
package espresso

import github.com/beans-lang/barista
import std.reflect

/// Registers every linked `@barista.service` class into this builder.
///
/// The scan itself is barista's. What espresso adds is one refusal: a
/// `@controller` is already a scoped service via `add_controllers`, so
/// `@service` on one would register it twice under the same name, silently
/// replacing it. barista knows nothing about controllers, so the refusal is
/// passed in as a closure rather than taught to barista as a new category.
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
