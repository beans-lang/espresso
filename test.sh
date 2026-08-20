#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
BEANS_ROOT=${BEANS_ROOT:-$(cd "$ROOT/../../beans" && pwd)}
BEANSC=${BEANSC:-$BEANS_ROOT/build/beansc}

if [[ ! -x "$BEANSC" ]]; then
    echo "beansc not found at $BEANSC" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$BEANS_ROOT"

cases=(di routing config_logging features fuzz server)
for name in "${cases[@]}"; do
    "$BEANSC" run "$ROOT/tests/$name.b" >"$tmp/$name.interp"
    diff -u "$ROOT/tests/$name.out" "$tmp/$name.interp"
done

for target in x86_64-unknown-linux-gnu x86_64-pc-windows-gnu aarch64-apple-darwin; do
    "$BEANSC" check "$ROOT/tests/server.b" --target "$target" >/dev/null
done

if [[ ${1:-} == "--native" ]]; then
    "$BEANSC" build "$ROOT/tests/smoke.b" -o "$tmp/smoke" >/dev/null
    "$tmp/smoke" >"$tmp/smoke.native"
    diff -u "$ROOT/tests/smoke.out" "$tmp/smoke.native"
fi

echo "ok espresso: interpreter, target checks${1:+, native}"
