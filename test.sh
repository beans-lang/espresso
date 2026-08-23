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

cases=(di routing config_logging features fuzz server defer docs mvc binding_fuzz di_scan di_scan_bad di_scan_conflict async_pipeline pool_async server_async serve_async)
for name in "${cases[@]}"; do
    "$BEANSC" run "$ROOT/tests/$name.b" >"$tmp/$name.interp"
    diff -u "$ROOT/tests/$name.out" "$tmp/$name.interp"
done

if [[ ${ESPRESSO_SLOW:-} == 1 ]]; then
    "$BEANSC" run "$ROOT/tests/server_scale.b" >"$tmp/server_scale.interp"
    diff -u "$ROOT/tests/server_scale.out" "$tmp/server_scale.interp"
fi

for target in x86_64-unknown-linux-gnu x86_64-pc-windows-gnu aarch64-apple-darwin; do
    "$BEANSC" check "$ROOT/tests/server.b" --target "$target" >/dev/null
done

if [[ ${1:-} == "--native" ]]; then
    "$BEANSC" build "$ROOT/tests/smoke.b" -o "$tmp/smoke" >/dev/null
    "$tmp/smoke" >"$tmp/smoke.native"
    diff -u "$ROOT/tests/smoke.out" "$tmp/smoke.native"
fi

echo "ok espresso: interpreter, target checks${1:+, native}${ESPRESSO_SLOW:+, slow}"
