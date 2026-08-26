#!/usr/bin/env python3
"""Scoring for the `latency-1m` profile.

Every other profile here ranks on one number, requests per second. This one
cannot: the rate is pinned, so every entry that finishes serves the same load
and the interesting differences are in what it cost and how the tail behaved.

The score is

    rateFactor = min(1, achieved_rps / 950_000)
    quality    = 0.60*cpuScore + 0.25*p99Score + 0.15*p999Score
    score      = 100 * rateFactor * quality

with, against the best value present in the field:

    cpuScore   = bestCpu / cpu                       (linear)
    p99Score   = 1 - log10(p99  / bestP99 ) / 3      (clamped to 0..1)
    p999Score  = 1 - log10(p999 / bestP999) / 3      (clamped to 0..1)

Why the two shapes differ. CPU per request spans about 3.3x across the entries
that hold the rate, so a plain ratio behaves well over it. The latency tails
span five orders of magnitude - 151us to 7.6s at p99 among rate-holders - and a
plain ratio there collapses to near zero for everything but the leader, spending
40% of the weight without separating anybody. A decade scale keeps the whole
field distinguishable while still charging heavily for a bad tail: ten times the
best costs a third of the term, a thousand times costs all of it.

The 3-decade span is fixed rather than derived from the worst entry on purpose,
so one pathological entry joining the board cannot move everybody else's score.
For the same reason nothing is rescaled to make the leader exactly 100: the top
entry scores in the low-to-mid 90s because no single entry is simultaneously
best on cost and on both tails, and that gap is information.

Two modes:

    latency_1m_score.py --pick <dir>   pick the best of N runs (benchmark.sh)
    latency_1m_score.py --table        score the published results
"""

from __future__ import annotations
import argparse
import json
import math
import re
import sys
from pathlib import Path

RATE_FULL = 950_000.0
W_CPU, W_P99, W_P999 = 0.60, 0.25, 0.15
DECADES = 3.0


def to_us(value) -> float | None:
    """'173.0us' / '1.5ms' / '2s' -> microseconds. None when unparseable."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    m = re.match(r"\s*([\d.]+)\s*(us|ms|s)?\s*$", str(value))
    if not m:
        return None
    v = float(m.group(1))
    return v * {"us": 1.0, "ms": 1e3, "s": 1e6, None: 1.0}[m.group(2)]


def _clamp(v: float) -> float:
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def rate_factor(rps: float) -> float:
    return _clamp(rps / RATE_FULL)


def decade_score(value: float | None, best: float | None) -> float:
    """1.0 at the best value, falling a third per decade above it."""
    if not value or not best or value <= 0 or best <= 0:
        return 0.0
    return _clamp(1.0 - math.log10(max(value, best) / best) / DECADES)


def linear_score(value: float | None, best: float | None) -> float:
    if not value or not best or value <= 0 or best <= 0:
        return 0.0
    return _clamp(best / value)


def score_rows(rows: list[dict]) -> list[dict]:
    """Annotate rows with their score. Each row needs rps, cpu, p99, p999.

    Bests are taken over the rows given, so a caller scoring one framework's
    three runs gets them normalised against each other, and a caller scoring the
    board gets them normalised against the field.
    """
    def best_of(key):
        vals = [r[key] for r in rows if r.get(key)]
        return min(vals) if vals else None

    b_cpu, b_p99, b_p999 = best_of("cpu"), best_of("p99"), best_of("p999")
    for r in rows:
        rf = rate_factor(r.get("rps") or 0)
        cpu_s = linear_score(r.get("cpu"), b_cpu)
        p99_s = decade_score(r.get("p99"), b_p99)
        p999_s = decade_score(r.get("p999"), b_p999)
        r["rateFactor"] = rf
        r["cpuScore"], r["p99Score"], r["p999Score"] = cpu_s, p99_s, p999_s
        r["score"] = 100.0 * rf * (W_CPU * cpu_s + W_P99 * p99_s + W_P999 * p999_s)
    return rows


def _kv(path: Path) -> dict:
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def pick(dirpath: str) -> int | None:
    """Best of the runs recorded under dirpath. Prints nothing on failure."""
    d = Path(dirpath)
    rows = []
    for kv_file in sorted(d.glob("*.kv")):
        n = kv_file.stem
        if not n.isdigit():
            continue
        kv = _kv(kv_file)
        meta = _kv(d / f"{n}.meta") if (d / f"{n}.meta").exists() else {}
        try:
            reqs = float(kv.get("status_2xx") or 0)
            cpu_usec = float(meta.get("cpu_usec") or 0)
        except ValueError:
            reqs = cpu_usec = 0.0
        rows.append({
            "run": int(n),
            "rps": float(kv.get("rps") or 0),
            # Per-request CPU, which is what the published metric is. Falls back
            # to None when the cgroup read failed, and linear_score treats that
            # as zero rather than as free.
            "cpu": (cpu_usec / reqs) if (reqs > 0 and cpu_usec > 0) else None,
            "p99": to_us(kv.get("p99_lat")),
            "p999": to_us(kv.get("p999_lat")),
        })
    if not rows:
        return None
    score_rows(rows)
    return max(rows, key=lambda r: (r["score"], r["rps"]))["run"]


def table(results_dir: Path) -> None:
    rows = []
    for f in sorted(results_dir.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        for key, r in (d.get("results") or {}).items():
            if not key.startswith("latency-1m-"):
                continue
            rows.append({
                "fw": d.get("framework", f.stem),
                "rps": r.get("rps") or 0,
                "cpu": r.get("cpu_per_req_us"),
                "p99": to_us(r.get("p99_latency")),
                "p999": to_us(r.get("p99_9_latency")),
            })
    if not rows:
        print("no latency-1m results found", file=sys.stderr)
        return
    score_rows(rows)
    rows.sort(key=lambda r: -r["score"])
    print("%-24s %7s %7s %9s %11s %12s" %
          ("framework", "score", "rate", "us/req", "p99", "p99.9"))
    for r in rows:
        print("%-24s %7.1f %7.3f %9s %11s %12s" % (
            r["fw"], r["score"], r["rateFactor"],
            "-" if r["cpu"] is None else f"{r['cpu']:.1f}",
            "-" if r["p99"] is None else f"{r['p99']:.0f}",
            "-" if r["p999"] is None else f"{r['p999']:.0f}"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pick", metavar="DIR", help="print the winning run number")
    ap.add_argument("--table", action="store_true", help="score published results")
    ap.add_argument("--results", default=None, help="results dir for --table")
    a = ap.parse_args()
    if a.pick:
        w = pick(a.pick)
        if w is None:
            return 1
        print(w)
        return 0
    if a.table:
        root = Path(__file__).resolve().parent.parent
        table(Path(a.results) if a.results else root / "site" / "data" / "results")
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
