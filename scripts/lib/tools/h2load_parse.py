#!/usr/bin/env python3
"""Validate completed h2load runs before emitting benchmark metrics."""

import re
import sys
from collections import Counter
from decimal import Decimal


def one(pattern, output, label):
    matches = re.findall(pattern, output, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"expected one {label}, found {len(matches)}")
    return matches[0]


def parse_run(output):
    elapsed, unit, bandwidth = one(
        r"^finished in ([\d.]+)(us|ms|s), [\d.]+ req/s, ([\d.]+[KMGT]?B/s)\s*$",
        output, "completion summary",
    )
    duration = Decimal(elapsed) * {"us": Decimal("0.000001"), "ms": Decimal("0.001"), "s": Decimal(1)}[unit]
    if duration <= 0:
        raise ValueError("measurement duration must be positive")
    counts = one(
        r"^requests:\s*(\d+) total,\s*(\d+) started,\s*(\d+) done,\s*(\d+) succeeded,\s*(\d+) failed,\s*(\d+) errored,\s*(\d+) timeout\s*$",
        output, "request summary",
    )
    _, _, done, succeeded, failed, errored, timeout = map(int, counts)
    if failed or errored or timeout:
        raise ValueError(f"unsuccessful requests: {failed} failed, {errored} errored, {timeout} timeout")
    if succeeded <= 0 or succeeded != done:
        raise ValueError("no complete, successful measurement")
    statuses = tuple(map(int, one(
        r"^status codes:\s*(\d+) 2xx,\s*(\d+) 3xx,\s*(\d+) 4xx,\s*(\d+) 5xx\s*$",
        output, "HTTP status summary",
    )))
    if statuses[0] < succeeded or any(statuses[1:]):
        raise ValueError("successful requests must have HTTP 2xx responses")

    metrics = {
        "rps": succeeded / duration,
        "duration": f"{duration}s",
        "avg_lat": "",
        "p99_lat": "",
        "max_lat": "",
        "reconnects": 0,
        "bandwidth": bandwidth,
        **{f"status_{code}xx": count for code, count in zip(range(2, 6), statuses)},
    }
    latency = re.search(r"^\s*(time for request|request)\s*:\s*(.+)$", output, re.MULTILINE)
    if latency:
        percentiles = latency[1] == "request"
        columns = latency[2].split()
        if len(columns) < (8 if percentiles else 5):
            raise ValueError("incomplete latency summary")
        metrics["max_lat"] = columns[1]
        metrics["avg_lat"] = columns[5] if percentiles else columns[2]
        if percentiles:
            metrics["p99_lat"] = columns[4]
    return metrics


def parse(output, endpoint):
    if endpoint != "production-stack":
        return parse_run(output)
    if output.count("=== h2load-reads ===") != 1 or output.count("=== h2load-writes ===") != 1:
        raise ValueError("missing production read/write output")
    _, reads = output.split("=== h2load-reads ===", 1)
    reads, writes = reads.split("=== h2load-writes ===", 1)
    result = parse_run(reads)
    write_metrics = parse_run(writes)
    result["rps"] += write_metrics["rps"]
    for code in range(2, 6):
        result[f"status_{code}xx"] += write_metrics[f"status_{code}xx"]
    return result


def diagnose(lines):
    counts = {}
    failures = {}
    section = "requests"
    for line in lines:
        if line.startswith("=== h2load-"):
            section = line.strip().removeprefix("=== h2load-").removesuffix(" ===")
        record = re.fullmatch(r"(\d+)\t(-?\d+)\t(\d+)\s*", line)
        if record:
            status = int(record[2])
            counts.setdefault(section, Counter())[status] += 1
            samples = failures.setdefault(section, [])
            if not 200 <= status < 300 and len(samples) < 5:
                samples.append((record[1], status, record[3]))
        elif line.startswith(("finished in ", "requests:", "status codes:")):
            print(f"[diagnostic] {section}: {line.strip()}")
    for section, statuses in counts.items():
        summary = ", ".join(
            f"{'stream error' if code == -1 else f'HTTP {code}'}={count}"
            for code, count in sorted(statuses.items())
        )
        print(f"[diagnostic] {section}: {summary}")
        for started, status, duration in failures[section]:
            print(f"[diagnostic] {section}: start_us={started} status={status} duration_us={duration}")
    if not counts:
        print("[diagnostic] no per-request records; replay did not complete requests")


def main():
    if sys.argv[1] == "--diagnostic":
        diagnose(sys.stdin)
        return 0
    try:
        metrics = parse(sys.stdin.read(), sys.argv[1])
    except (ValueError, ArithmeticError) as error:
        print(f"invalid h2load measurement: {error}", file=sys.stderr)
        return 1
    metrics["rps"] = int(metrics["rps"])
    for key, value in metrics.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
