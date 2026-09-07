#!/usr/bin/env bash
# Resident-memory gate for the bounded output queue.
#
# tests/output_rss.b holds 8 keep-alive connections open, each having pipelined
# 200 requests in one burst and drained all 200 responses, then parks. This
# driver waits for its "ready" marker, samples the process's peak RSS while all
# 8 are live and IDLE — the state the report is about, a connection that has
# served a burst and is waiting for its next request — checks it against a
# threshold, then lets the program go.
#
# It measures the NATIVE binary: under the tree interpreter the process is the
# whole compiler and its baseline RSS dwarfs the thing under test.
#
# Before the queue was bounded (beans-lang/espresso#7), one read carried the
# whole burst, so all 200 responses were framed into the connection's output
# queue before it flushed; at 15,000 bytes each — just under vectored_body_min,
# so copied into the queue rather than sent beside the head — the queue grew to
# 3,026,000 bytes and resize(0) freed none of it. Eight connections retained
# ~24 MiB while idle and the process measured ~29 MiB here. With the queue
# bounded and released once it outgrows the bound, the peak is the process's
# baseline, ~5 MiB.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

# The ceiling, in KB. 10 MiB is the target the issue names; the pre-fix
# measurement is ~29 MiB and the post-fix one ~5 MiB, so the limit sits well
# clear of both.
RSS_LIMIT_KB=${OUTPUT_RSS_LIMIT_KB:-10240}

# Resolve the compiler the way test.sh does.
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
fifo="$tmp/in"
mkfifo "$fifo"
pid=""
cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    exec 9>&- 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

# A tree-built beansc resolves the runtime and stdlib relative to the cwd; the
# espresso package still resolves from the test file's own directory.
if [[ -n ${BEANS_ROOT:-} && "$BEANSC" == "$BEANS_ROOT/build/beansc" ]]; then
    cd "$BEANS_ROOT"
fi

"$BEANSC" build "$ROOT/tests/output_rss.b" -o "$tmp/output_rss" >/dev/null

# Hold the fifo's write end open on fd 9 so the program's stdin does not see EOF
# before we answer it.
exec 9<>"$fifo"
"$tmp/output_rss" <"$fifo" >"$tmp/out" 2>"$tmp/err" &
pid=$!

# Wait for the "ready" marker (stderr, unbuffered) — printed only once all 8
# connections have drained their burst and are holding.
ready=""
for _ in $(seq 1 600); do
    if grep -q '^ready' "$tmp/err" 2>/dev/null; then ready=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if [[ -z "$ready" ]]; then
    echo "output rss gate: the server never signalled ready" >&2
    cat "$tmp/err" >&2
    exit 1
fi
readline=$(grep '^ready' "$tmp/err" | head -1)
if ! echo "$readline" | grep -q 'arrived 8 failed 0'; then
    echo "output rss gate: the 8 connections did not all arrive cleanly: $readline" >&2
    exit 1
fi

# Peak RSS over ~2s while all 8 connections are held open and idle.
peak=0
for _ in $(seq 1 20); do
    r=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$r" && "$r" -gt "$peak" ]]; then peak=$r; fi
    sleep 0.1
done

# Release the connections and let the program exit.
echo go >&9
wait "$pid" 2>/dev/null || true
pid=""

# The program's last line reports what the server counted. A run that served
# fewer than 8 * 200 requests measured the wrong thing, so refuse it.
tally=$(grep '^requests ' "$tmp/out" | head -1)
if [[ -z "$tally" ]]; then
    echo "output rss gate: the server printed no tally" >&2
    cat "$tmp/out" "$tmp/err" >&2
    exit 1
fi
if ! echo "$tally" | grep -q '^requests 1600 responses 1600 '; then
    echo "output rss gate: wrong traffic served: $tally" >&2
    exit 1
fi

echo "output rss gate: $tally"
echo "output rss gate: peak resident ${peak} KB (~$((peak/1024)) MiB), limit ${RSS_LIMIT_KB} KB (~$((RSS_LIMIT_KB/1024)) MiB)"
if [[ "$peak" -le "$RSS_LIMIT_KB" ]]; then
    echo "output rss gate: PASS"
else
    echo "output rss gate: FAIL — 8 idle connections retain the burst they framed" >&2
    exit 1
fi
