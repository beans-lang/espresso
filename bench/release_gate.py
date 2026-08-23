#!/usr/bin/env python3
"""Record or compare Espresso's five-sample release performance gates."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import resource
import socket
import statistics
import subprocess
import sys
from pathlib import Path

SAMPLE_COUNT = 5
MAX_CV = 0.05
LIVE_MEASURED_REQUESTS = 20_000
GATES = {
    "sync_testhost_rps": ("min", 0.90),
    "async_no_await_rps": ("min", 0.80),
    "live_rps": ("min", 0.85),
    "live_p99_nanos": ("max", 1.25),
    "live_cpu_nanos_per_request": ("max", 1.20),
}
UNITS = {
    "sync_testhost_rps": "requests_per_second",
    "async_no_await_rps": "requests_per_second",
    "live_rps": "requests_per_second",
    "live_p99_nanos": "nanoseconds",
    "live_cpu_nanos_per_request": "nanoseconds_per_request",
}


def parse_metrics(output: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in output.splitlines():
        pieces = line.split("\t")
        if len(pieces) == 3:
            values[pieces[0]] = int(pieces[2])
    return values


def run(binary: Path) -> tuple[dict[str, int], int]:
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    completed = subprocess.run(
        [str(binary)], check=True, text=True, capture_output=True
    )
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu_seconds = (
        after.ru_utime - before.ru_utime + after.ru_stime - before.ru_stime
    )
    return parse_metrics(completed.stdout), int(cpu_seconds * 1_000_000_000)


def cpu_identity() -> str:
    if sys.platform == "darwin":
        try:
            return subprocess.check_output(
                ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            pass
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.exists():
        for line in cpuinfo.read_text(errors="replace").splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[-1].strip()
    return platform.processor() or "unknown"


def series_record(values: list[int], unit: str) -> dict[str, object]:
    mean = statistics.fmean(values)
    cv = 0.0 if mean == 0 else statistics.pstdev(values) / mean
    return {
        "unit": unit,
        "samples": values,
        "median": statistics.median(values),
        "mean": mean,
        "cv": cv,
    }


def settings(
    compiler_version: str, compiler_sha256: str, beans_revision: str
) -> dict[str, object]:
    return {
        "sample_count": SAMPLE_COUNT,
        "max_cv": MAX_CV,
        "build": ["--release", "--lto"],
        "sync_warmup_requests": 5000,
        "sync_measured_requests": 100000,
        "async_warmup_requests": 5000,
        "async_measured_requests": 100000,
        "testhost_processes": (
            "candidate lanes separate with alternating order; "
            "legacy sync sample copied to both gates"
        ),
        "live_warmup_requests": 2000,
        "live_measured_requests": LIVE_MEASURED_REQUESTS,
        "live_warmup_process": "separate and excluded from CPU sample",
        "live_cpu_scope": "measured process total",
        "hostname": socket.gethostname(),
        "machine": platform.platform(),
        "architecture": platform.machine(),
        "cpu_model": cpu_identity(),
        "logical_cpu_count": os.cpu_count(),
        "compiler": compiler_version,
        "beansc_sha256": compiler_sha256,
        "beans_revision": beans_revision,
    }


def collect(
    sync_testhost: Path,
    async_testhost: Path,
    live_warmup: Path,
    live: Path,
    compiler_version: str,
    compiler_sha256: str,
    beans_revision: str,
    source_revision: str,
    legacy_baseline: bool,
) -> tuple[dict, list]:
    samples = {name: [] for name in GATES}
    rows: list[tuple[str, str, int, int]] = []
    for sample in range(1, SAMPLE_COUNT + 1):
        if legacy_baseline:
            host_values, _ = run(sync_testhost)
            value = host_values["testhost_rps"]
            for name in ("sync_testhost_rps", "async_no_await_rps"):
                samples[name].append(value)
                rows.append((name, UNITS[name], sample, value))
        else:
            lanes = [
                ("sync_testhost_rps", sync_testhost),
                ("async_no_await_rps", async_testhost),
            ]
            if sample % 2 == 0:
                lanes.reverse()
            for name, binary in lanes:
                host_values, _ = run(binary)
                value = host_values["testhost_rps"]
                samples[name].append(value)
                rows.append((name, UNITS[name], sample, value))

        run(live_warmup)
        live_values, cpu_nanos = run(live)
        for name in ("live_rps", "live_p99_nanos"):
            value = live_values[name]
            samples[name].append(value)
            rows.append((name, UNITS[name], sample, value))
        cpu_per_request = cpu_nanos // LIVE_MEASURED_REQUESTS
        samples["live_cpu_nanos_per_request"].append(cpu_per_request)
        rows.append((
            "live_cpu_nanos_per_request",
            UNITS["live_cpu_nanos_per_request"],
            sample,
            cpu_per_request,
        ))

    result = {
        "schema": "espresso-release-bench-v2",
        "source_revision": source_revision,
        "working_tree_clean": True,
        "settings": settings(
            compiler_version, compiler_sha256, beans_revision
        ),
        "gates": {
            name: {"direction": direction, "factor": factor}
            for name, (direction, factor) in GATES.items()
        },
        "metrics": {
            name: series_record(values, UNITS[name])
            for name, values in samples.items()
        },
    }
    return result, rows


def write_tsv(path: Path, rows: list[tuple[str, str, int, int]]) -> None:
    lines = ["metric\tunit\tsample\tvalue"]
    lines.extend("\t".join(map(str, row)) for row in rows)
    path.write_text("\n".join(lines) + "\n")


def noise_failures(result: dict) -> list[str]:
    failures = []
    for name, metric in result["metrics"].items():
        cv = float(metric["cv"])
        if not math.isfinite(cv) or cv > MAX_CV:
            failures.append(f"{name}: CV {cv:.4f} exceeds {MAX_CV:.2f}")
    return failures


def compare(candidate: dict, baseline: dict) -> list[str]:
    failures = []
    if candidate["schema"] != baseline.get("schema"):
        return ["baseline schema does not match"]
    if candidate["settings"] != baseline.get("settings"):
        return ["baseline machine/build/compiler settings do not match candidate"]
    if baseline.get("working_tree_clean") is not True:
        failures.append("baseline was not recorded from a clean worktree")
    for name, (direction, factor) in GATES.items():
        current = float(candidate["metrics"][name]["median"])
        origin = float(baseline["metrics"][name]["median"])
        passed = (
            current >= origin * factor
            if direction == "min"
            else current <= origin * factor
        )
        word = ">=" if direction == "min" else "<="
        print(f"{name}: {current:g} {word} {origin * factor:g}")
        if not passed:
            failures.append(
                f"{name}: candidate {current:g}, baseline {origin:g}, "
                f"gate {factor:.2f}x"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("record", "compare"))
    parser.add_argument("--sync-testhost", required=True, type=Path)
    parser.add_argument("--async-testhost", required=True, type=Path)
    parser.add_argument("--live-warmup", required=True, type=Path)
    parser.add_argument("--live", required=True, type=Path)
    parser.add_argument("--compiler-version", required=True)
    parser.add_argument("--compiler-sha256", required=True)
    parser.add_argument("--beans-revision", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--expected-baseline-revision")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tsv", required=True, type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()

    baseline = None
    failures: list[str] = []
    if args.mode == "compare":
        if args.baseline is None or args.expected_baseline_revision is None:
            failures.append(
                "compare needs --baseline and --expected-baseline-revision"
            )
        else:
            baseline = json.loads(args.baseline.read_text())
            if baseline.get("source_revision") != args.expected_baseline_revision:
                failures.append(
                    "baseline source revision does not match the supplied revision"
                )
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    candidate, rows = collect(
        args.sync_testhost,
        args.async_testhost,
        args.live_warmup,
        args.live,
        args.compiler_version,
        args.compiler_sha256,
        args.beans_revision,
        args.source_revision,
        args.mode == "record",
    )
    args.output.write_text(json.dumps(candidate, indent=2, sort_keys=True) + "\n")
    write_tsv(args.tsv, rows)
    failures.extend(noise_failures(candidate))
    if baseline is not None:
        failures.extend(noise_failures(baseline))
        failures.extend(compare(candidate, baseline))
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"wrote {args.output} and {args.tsv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
