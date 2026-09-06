#!/usr/bin/env bash
# Resident-memory gate for the borrowed-body work.
#
# tests/rss.b holds 32 keep-alive connections open, each served one 1 MiB
# response, then parks. This driver waits for its "ready" marker, samples the
# process's peak RSS while all 32 are live, checks it against a threshold, then
# lets the program go.
#
# It measures the NATIVE binary: under the tree interpreter the process is the
# whole compiler and its baseline RSS dwarfs the thing under test.
#
# Before the body is borrowed (issue beans-lang/beans#140, item 2) every
# connection keeps the megabyte its HttpResponse.body grew to (resize(0) frees
# no pages), so 32 connections retain ~32 MiB — the bulk of the ~38.8 MiB the
# /static1m ledger reports under wrk -c32; the process peaks near 41 MiB here.
#
# Borrowing the string payload removes that per-connection copy and drops the
# peak to ~24 MiB. The last step to the 12 MiB target is TcpStream
# .write_vectored_text: until it exists, a large string body is copied once into
# a fresh per-send buffer to be sent beside its head, and under 32-way
# concurrency those buffers set the allocator's high-water mark near 32 MiB and
# it is not returned to the OS. With write_vectored_text the string is sent with
# no such buffer and the peak falls under 12 MiB; after lane A's mmap-backed
# static body the target tightens to 10 MiB (set RSS_LIMIT_KB=10240).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)

# The ceiling, in KB. 12 MiB is the borrowed-body target; the pre-fix baseline
# is ~40 MiB, and the post-mmap target is 10240.
RSS_LIMIT_KB=${RSS_LIMIT_KB:-12288}

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

"$BEANSC" build "$ROOT/tests/rss.b" -o "$tmp/rss" >/dev/null

# Hold the fifo's write end open on fd 9 so the program's stdin does not see EOF
# before we answer it.
exec 9<>"$fifo"
"$tmp/rss" <"$fifo" >"$tmp/out" 2>"$tmp/err" &
pid=$!

# Wait for the "ready" marker (stderr, unbuffered) — printed only once all 32
# connections are holding.
ready=""
for _ in $(seq 1 400); do
    if grep -q '^ready' "$tmp/err" 2>/dev/null; then ready=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if [[ -z "$ready" ]]; then
    echo "rss gate: the server never signalled ready" >&2
    cat "$tmp/err" >&2
    exit 1
fi
readline=$(grep '^ready' "$tmp/err" | head -1)
if ! echo "$readline" | grep -q 'arrived 32 failed 0'; then
    echo "rss gate: the 32 connections did not all arrive cleanly: $readline" >&2
    exit 1
fi

# Peak RSS over ~2s while all 32 responses are held open.
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

echo "rss gate: peak resident ${peak} KB (~$((peak/1024)) MiB), limit ${RSS_LIMIT_KB} KB (~$((RSS_LIMIT_KB/1024)) MiB)"
if [[ "$peak" -le "$RSS_LIMIT_KB" ]]; then
    echo "rss gate: PASS"
else
    echo "rss gate: FAIL — 32 held 1 MiB responses retain too much resident memory" >&2
    exit 1
fi
