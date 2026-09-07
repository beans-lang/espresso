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

# panic.b routes a handler panic through the same detailed_errors gate a
# returned err uses, and writes the server-side record the generic response
# promises. That record goes to stderr by default, so its stdout golden cannot
# see it — assert it here instead. The secrets and trace id mirror
# tests/panic.b: Case A (production) and Case B (detailed_errors) use the
# default stderr sink, so their secrets MUST appear; Case C supplies a logger,
# so its secret MUST NOT reach stderr — that is the "a supplied handler
# instead of stderr" branch.
assert_panic_stderr() {
    local err="$1"
    local leg="$2"
    grep -q "alpha-4471-hunter2" "$err" || {
        echo "panic ($leg): stderr missing the production (Case A) record" >&2
        cat "$err" >&2; exit 1; }
    grep -q "bravo-5582-swordfish" "$err" || {
        echo "panic ($leg): stderr missing the detailed_errors (Case B) record" >&2
        cat "$err" >&2; exit 1; }
    grep -q "runtime panic at" "$err" || {
        echo "panic ($leg): stderr record dropped the source position" >&2
        cat "$err" >&2; exit 1; }
    grep -q "traceId=espresso-1" "$err" || {
        echo "panic ($leg): stderr record dropped the trace id" >&2
        cat "$err" >&2; exit 1; }
    if grep -q "charlie-6693-correcthorse" "$err"; then
        echo "panic ($leg): Case C secret reached stderr despite a supplied logger" >&2
        cat "$err" >&2; exit 1
    fi
}

cases=(di routing config_logging features fuzz server defer panic docs mvc binding_fuzz di_scan di_scan_bad di_scan_conflict date panic_reclaim di_panic defer_panic large_body bytes_body borrow server_header body_release head_cache output_release cookies upgrade stream form multipart)
for name in "${cases[@]}"; do
    if ! "$BEANSC" run "$ROOT/tests/$name.b" \
            >"$tmp/$name.interp" 2>"$tmp/$name.interp.err"; then
        cat "$tmp/$name.interp.err" >&2
        exit 1
    fi
    diff -u "$ROOT/tests/$name.out" "$tmp/$name.interp"
done
assert_panic_stderr "$tmp/panic.interp.err" "interpreter"

for target in x86_64-unknown-linux-gnu x86_64-pc-windows-gnu aarch64-apple-darwin; do
    "$BEANSC" check "$ROOT/tests/server.b" --target "$target" >/dev/null
done

if [[ ${1:-} == "--native" ]]; then
    # The contained-panic unwind is a native-codegen feature (the unwind pads
    # in the LLVM backend), so the reclamation, deferred-abandon and Date
    # suites run natively too, not only under the interpreter — the interpreter
    # leg cannot fail the way native can. `panic` joins them: the info-leak fix
    # rides that same unwind, and its stderr and logger records must survive
    # native codegen, not only the tree walker.
    # `multipart` joins them because it is a byte-level parser driven over
    # every two-way split of eleven bodies, and it draws its storage ids from
    # std.random — a bridge the interpreter and the native build reach
    # differently.
    #
    # `form` joins them because it decodes percent escapes byte by byte and
    # binds through reflection, and both are emitted per backend.
    #
    # `stream` joins them because a chunked response is written straight to
    # the socket by the handler's own fiber — vectored writes, a 200 KB chunk,
    # a truncated body on failure — and none of that is exercised by the
    # buffered path the other suites drive.
    #
    # `upgrade` joins them because it hands a live socket from the connection
    # fiber to another protocol and then reads and writes it. The first native
    # run of it caught a real difference from the interpreter — the 101 head
    # and the frame behind it arrive in one segment natively and in two under
    # the interpreter — which is exactly the class of bug an interpreter-only
    # gate cannot see.
    #
    # `cookies` joins them because it sweeps every byte value through the
    # name and value rules and then drives a real keep-alive socket: a
    # string-byte or a socket difference between the backends would show up
    # nowhere else.
    #
    # `docs` joins them because it is the widest reflection surface in the
    # suite — the controller scanner, @service discovery, and now
    # provider.activate() calling an initializer through reflect — and
    # reflection metadata is emitted by the backend, not shared with the
    # interpreter. It ran interpreter-only for its whole life.
    native_cases=(smoke date panic_reclaim di_panic defer_panic panic large_body bytes_body borrow server_header body_release head_cache output_release docs cookies upgrade stream form multipart)
    for name in "${native_cases[@]}"; do
        "$BEANSC" build "$ROOT/tests/$name.b" -o "$tmp/$name" >/dev/null
        if ! "$tmp/$name" >"$tmp/$name.native" 2>"$tmp/$name.native.err"; then
            cat "$tmp/$name.native.err" >&2
            exit 1
        fi
        diff -u "$ROOT/tests/$name.out" "$tmp/$name.native"
    done
    assert_panic_stderr "$tmp/panic.native.err" "native"

    # The resident-memory gates: 32 keep-alive connections each served one 1 MiB
    # response must hold well under the limit once the response borrows its
    # payload instead of copying it (beans-lang/beans#140). Native only — under
    # the interpreter the process is the whole compiler. They measure RSS, not
    # throughput, so a busy box does not flake them.
    #
    # One per payload form. `rss` drives the string path, where all 32 requests
    # share one payload; `rss_bytes` drives the bytes path, where each request
    # is answered from its own BytesResult — a form the string gate cannot
    # speak for, and whose copy therefore sat unmeasured through a green suite.
    bash "$ROOT/rss_gate.sh" rss
    bash "$ROOT/rss_gate.sh" rss_bytes

    # The output-queue gate: 8 keep-alive connections that each pipelined 200
    # requests in one burst, held OPEN and idle afterwards, must not still be
    # holding the batch they framed (beans-lang/espresso#7). Native only, for
    # the same reason as the gates above, and it measures RSS while the
    # connections are parked, so a busy box does not flake it.
    bash "$ROOT/output_rss_gate.sh"
fi

echo "ok espresso: interpreter, target checks${1:+, native}"
