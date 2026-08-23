#!/usr/bin/env python3
"""Keep Espresso's breaking 0.3 public surface exact."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def flat(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def require(text: str, pattern: str, label: str, failures: list[str]) -> None:
    if re.search(pattern, text) is None:
        failures.append(f"missing {label}")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    library_files = sorted(root.glob("*.b"))
    library = flat("\n".join(path.read_text() for path in library_files))
    public_tree = "\n".join(
        path.read_text()
        for path in sorted(root.rglob("*"))
        if path.is_file()
        and (
            path.suffix == ".b"
            or (path.suffix == ".md" and path.name != "CHANGELOG.md")
        )
    )
    failures: list[str] = []

    forbidden = {
        r"\bResponder\b": "Responder",
        r"\bCompletion\b": "Completion",
        r"\bLoopMailbox\b": "LoopMailbox",
        r"\brespond_later\s*\(": "respond_later call",
        r"\brespond_now\s*\(": "respond_now call",
        r"\bWorkerPool\.submit\b|\.submit\s*\(": "WorkerPool.submit call",
        r"\bpoll_timeout_ms\b|server:poll-timeout-ms": "poll timeout option",
        r"\bmax_events\b|server:max-events": "max events option",
    }
    for pattern, label in forbidden.items():
        if re.search(pattern, public_tree):
            failures.append(f"removed surface remains: {label}")

    require(
        library,
        r"pub fn use\(layer: async fn\(HttpContext, async fn\(HttpContext\) -> Result<bool>\) -> Result<bool>\) -> Result<bool>",
        "async function middleware signature",
        failures,
    )
    require(
        library,
        r"pub interface Middleware \{ async fn handle\(context: HttpContext, next: async fn\(HttpContext\) -> Result<bool>\) -> Result<bool>",
        "async Middleware.handle signature",
        failures,
    )
    require(
        library,
        r"pub interface Authorizer \{ async fn authorize\(context: HttpContext, policy: string\) -> Result<bool>",
        "async Authorizer.authorize signature",
        failures,
    )

    for verb in ("map", "get", "post", "put", "patch", "delete"):
        require(
            library,
            rf"pub fn {verb}\([^)]*handler: async fn\(HttpContext\) -> Result<ActionResult>\) -> Result<bool>",
            f"async-default {verb}",
            failures,
        )
        require(
            library,
            rf"pub fn {verb}_sync\([^)]*handler: fn\(HttpContext\) -> Result<ActionResult>\) -> Result<bool>",
            f"inline {verb}_sync adapter",
            failures,
        )

    require(
        library,
        r"pub async fn execute<T implements Send>\(move job: send fn\(\) -> T\) -> Result<T>",
        "WorkerPool.execute<T>",
        failures,
    )
    require(
        library,
        r"pub async fn close\(\) -> Result<bool>",
        "async WorkerPool.close",
        failures,
    )
    require(
        library,
        r"pub async fn run\(\) -> Result<ServerStats>",
        "async WebServer.run",
        failures,
    )
    require(
        library,
        r"pub async fn serve\(",
        "async serve",
        failures,
    )
    for method in ("send", "send_with_headers", "get", "post"):
        require(
            library,
            rf"pub async fn {method}\(",
            f"async TestHost.{method}",
            failures,
        )
    require(
        library,
        r"await self\.action\.call_async\(receiver, move arguments\)",
        "async controller reflection dispatch",
        failures,
    )
    require(
        library,
        r"pub class DetachedResult implements ActionResult",
        "DetachedResult compatibility type",
        failures,
    )

    if re.search(r"pub fn use\(layer: fn\(", library):
        failures.append("sync middleware adapter remains")
    if re.search(r"pub (?:class|struct|interface|fn|async fn) (?:Responder|Completion|LoopMailbox|respond_later|respond_now|submit)\b", library):
        failures.append("a removed public declaration remains")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("ok espresso api surface")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
