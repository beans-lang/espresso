#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
TARGET_ROOT=${ESPRESSO_ROOT:-$ROOT}

if [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../beans/build/beansc" ]]; then
    BEANS_ROOT=$(cd "$ROOT/../beans" && pwd)
elif [[ -z ${BEANS_ROOT:-} && -x "$ROOT/../../beans/build/beansc" ]]; then
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
    echo "beansc not found: set BEANSC and BEANS_ROOT" >&2
    exit 1
fi

mode=${1:-}
if [[ "$mode" == record ]]; then
    output=${2:-}
    baseline=
elif [[ "$mode" == compare ]]; then
    baseline=${2:-}
    output=${3:-}
else
    echo "usage: ./bench.sh record OUTPUT.json [OUTPUT.tsv]" >&2
    echo "       ./bench.sh compare BASELINE.json OUTPUT.json [OUTPUT.tsv]" >&2
    exit 1
fi
if [[ -z "$output" ]]; then
    echo "an output JSON path is required" >&2
    exit 1
fi
if [[ "$mode" == record ]] && grep -q "pub fn get_sync" "$TARGET_ROOT/app.b"; then
    echo "record needs the legacy origin/main Espresso checkout in ESPRESSO_ROOT" >&2
    exit 1
fi
if [[ "$mode" == compare ]] && ! grep -q "pub fn get_sync" "$TARGET_ROOT/app.b"; then
    echo "compare needs the async-v2 Espresso checkout in ESPRESSO_ROOT" >&2
    exit 1
fi
if [[ "$mode" == compare && -z "$baseline" ]]; then
    echo "a baseline JSON path is required" >&2
    exit 1
fi
if [[ "$mode" == record ]]; then
    raw=${3:-${output%.json}.tsv}
else
    raw=${4:-${output%.json}.tsv}
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/espresso/bench"
cp "$TARGET_ROOT"/*.b "$tmp/espresso/"
cp "$TARGET_ROOT/beans.pot" "$tmp/espresso/"
if [[ "$mode" == record ]]; then
    cp "$ROOT/bench/release_testhost_legacy.b" \
        "$tmp/espresso/bench/release_testhost.b"
    cp "$ROOT/bench/release_live_legacy.b" \
        "$tmp/espresso/bench/release_live.b"
else
    cp "$ROOT/bench/release_testhost.b" "$tmp/espresso/bench/"
    cp "$ROOT/bench/release_live.b" "$tmp/espresso/bench/"
fi

build_root=$PWD
if [[ -n ${BEANS_ROOT:-} && "$BEANSC" == "$BEANS_ROOT/build/beansc" ]]; then
    build_root=$BEANS_ROOT
fi
(
    cd "$build_root"
    "$BEANSC" build --release --lto \
        "$tmp/espresso/bench/release_testhost.b" \
        -o "$tmp/release_testhost"
    "$BEANSC" build --release --lto \
        "$tmp/espresso/bench/release_live.b" \
        -o "$tmp/release_live"
)

compiler_version=$($BEANSC --version | head -n 1)
source_revision=$(git -C "$TARGET_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
arguments=(
    "$mode"
    --testhost "$tmp/release_testhost"
    --live "$tmp/release_live"
    --compiler-version "$compiler_version"
    --source-revision "$source_revision"
    --output "$output"
    --tsv "$raw"
)
if [[ "$mode" == compare ]]; then
    arguments+=(--baseline "$baseline")
fi
python3 "$ROOT/bench/release_gate.py" "${arguments[@]}"
