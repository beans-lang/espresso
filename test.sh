#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

# A compiler built from a Beans checkout resolves the standard library and
# runtime relative to that checkout, so those runs happen from its root. An
# installed beansc carries its own, and runs from anywhere.
if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../../beans" && pwd)
fi
if [[ -z ${BEANSC:-} ]]; then
    if [[ -n ${BEANS_ROOT:-} && -x "$BEANS_ROOT/build/beansc" ]]; then
        BEANSC="$BEANS_ROOT/build/beansc"
    else
        BEANSC=$(command -v beansc || true)
    fi
fi

if [[ -z "$BEANSC" || ! -x "$BEANSC" ]]; then
    echo "beansc not found: set BEANSC, set BEANS_ROOT, or put beansc on PATH" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ -n ${BEANS_ROOT:-} && "$BEANSC" == "$BEANS_ROOT/build/beansc" ]]; then
    cd "$BEANS_ROOT"
fi

cases=(di routing config_logging features fuzz server defer panic docs mvc binding_fuzz di_scan di_scan_bad di_scan_conflict date panic_reclaim di_panic defer_panic)
for name in "${cases[@]}"; do
    "$BEANSC" run "$ROOT/tests/$name.b" >"$tmp/$name.interp"
    diff -u "$ROOT/tests/$name.out" "$tmp/$name.interp"
done

for target in x86_64-unknown-linux-gnu x86_64-pc-windows-gnu aarch64-apple-darwin; do
    "$BEANSC" check "$ROOT/tests/server.b" --target "$target" >/dev/null
done

if [[ ${1:-} == "--native" ]]; then
    # The contained-panic unwind is a native-codegen feature (the unwind pads
    # in the LLVM backend), so the reclamation, deferred-abandon and Date
    # suites run natively too, not only under the interpreter — the interpreter
    # leg cannot fail the way native can.
    native_cases=(smoke date panic_reclaim di_panic defer_panic)
    for name in "${native_cases[@]}"; do
        "$BEANSC" build "$ROOT/tests/$name.b" -o "$tmp/$name" >/dev/null
        "$tmp/$name" >"$tmp/$name.native"
        diff -u "$ROOT/tests/$name.out" "$tmp/$name.native"
    done
fi

echo "ok espresso: interpreter, target checks${1:+, native}"
