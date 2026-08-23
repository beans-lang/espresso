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
    expected_baseline_revision=${2:-}
    output=${3:-}
    baseline=
elif [[ "$mode" == compare ]]; then
    expected_baseline_revision=${2:-}
    baseline=${3:-}
    output=${4:-}
else
    echo "usage: ./bench.sh record BASELINE_COMMIT OUTPUT.json [OUTPUT.tsv]" >&2
    echo "       ./bench.sh compare BASELINE_COMMIT BASELINE.json OUTPUT.json [OUTPUT.tsv]" >&2
    exit 1
fi
if [[ ! "$expected_baseline_revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "BASELINE_COMMIT must be the exact 40-character commit id" >&2
    exit 1
fi
if [[ -z "$output" ]]; then
    echo "an output JSON path is required" >&2
    exit 1
fi
if [[ "$mode" == compare && -z "$baseline" ]]; then
    echo "a baseline JSON path is required" >&2
    exit 1
fi
if [[ "$mode" == record ]]; then
    raw=${4:-${output%.json}.tsv}
else
    raw=${5:-${output%.json}.tsv}
fi

if [[ -n $(git -C "$TARGET_ROOT" status --porcelain --untracked-files=normal) ]]; then
    echo "Espresso worktree is dirty: $TARGET_ROOT" >&2
    exit 1
fi
source_revision=$(git -C "$TARGET_ROOT" rev-parse HEAD)
if [[ "$mode" == record && "$source_revision" != "$expected_baseline_revision" ]]; then
    echo "record checkout is $source_revision, not supplied baseline $expected_baseline_revision" >&2
    exit 1
fi

beans_revision=unavailable
if [[ -n ${BEANS_ROOT:-} ]] && git -C "$BEANS_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n $(git -C "$BEANS_ROOT" status --porcelain --untracked-files=normal) ]]; then
        echo "Beans worktree is dirty: $BEANS_ROOT" >&2
        exit 1
    fi
    beans_revision=$(git -C "$BEANS_ROOT" rev-parse HEAD)
fi
compiler_sha256=$(shasum -a 256 "$BEANSC" | awk '{print $1}')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/espresso/bench"
cp "$TARGET_ROOT"/*.b "$tmp/espresso/"
cp "$TARGET_ROOT/beans.pot" "$tmp/espresso/"
if [[ "$mode" == record ]]; then
    cp "$ROOT/bench/release_testhost_legacy.b" \
        "$tmp/espresso/bench/release_testhost_sync.b"
    cp "$ROOT/bench/release_testhost_legacy.b" \
        "$tmp/espresso/bench/release_testhost_async.b"
    cp "$ROOT/bench/release_live_legacy.b" \
        "$tmp/espresso/bench/release_live.b"
    cp "$ROOT/bench/release_live_warmup_legacy.b" \
        "$tmp/espresso/bench/release_live_warmup.b"
else
    cp "$ROOT/bench/release_testhost_sync.b" "$tmp/espresso/bench/"
    cp "$ROOT/bench/release_testhost_async.b" "$tmp/espresso/bench/"
    cp "$ROOT/bench/release_live.b" "$tmp/espresso/bench/"
    cp "$ROOT/bench/release_live_warmup.b" "$tmp/espresso/bench/"
fi

build_root=$PWD
if [[ -n ${BEANS_ROOT:-} && "$BEANSC" == "$BEANS_ROOT/build/beansc" ]]; then
    build_root=$BEANS_ROOT
fi
(
    cd "$build_root"
    "$BEANSC" build --release --lto \
        "$tmp/espresso/bench/release_testhost_sync.b" \
        -o "$tmp/release_testhost_sync"
    "$BEANSC" build --release --lto \
        "$tmp/espresso/bench/release_testhost_async.b" \
        -o "$tmp/release_testhost_async"
    "$BEANSC" build --release --lto \
        "$tmp/espresso/bench/release_live.b" \
        -o "$tmp/release_live"
    "$BEANSC" build --release --lto \
        "$tmp/espresso/bench/release_live_warmup.b" \
        -o "$tmp/release_live_warmup"
)

compiler_version=$($BEANSC --version | head -n 1)
arguments=(
    "$mode"
    --sync-testhost "$tmp/release_testhost_sync"
    --async-testhost "$tmp/release_testhost_async"
    --live-warmup "$tmp/release_live_warmup"
    --live "$tmp/release_live"
    --compiler-version "$compiler_version"
    --compiler-sha256 "$compiler_sha256"
    --beans-revision "$beans_revision"
    --source-revision "$source_revision"
    --output "$output"
    --tsv "$raw"
)
if [[ "$mode" == compare ]]; then
    arguments+=(
        --baseline "$baseline"
        --expected-baseline-revision "$expected_baseline_revision"
    )
fi
python3 "$ROOT/bench/release_gate.py" "${arguments[@]}"
