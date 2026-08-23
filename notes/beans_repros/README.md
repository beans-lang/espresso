# Beans async lowering repros

Run each from the Beans checkout so imports use that standard library:

```sh
BEANSC=/path/to/beans/build/beansc
ESPRESSO=/path/to/espresso
cd /path/to/beans
for repro in return_await async_try branch_local closure_capture \
             unique_async_local preawait_local async_enum_move \
             reflect_error_binding; do
  "$BEANSC" run "$ESPRESSO/notes/beans_repros/$repro/main.b"
done
```

These files isolate four failures seen while compiling Espresso 0.3 against
Beans `de3ce2f`: stored `return await`, `?` in an async Result function,
locals across a suspending branch or loop, and renamed explicit captures in a
generic async function.
