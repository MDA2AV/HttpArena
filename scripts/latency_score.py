#!/usr/bin/env python3
"""Scoring for the fixed-rate profiles: `latency-1m`, `latency-10k`, `8gbit`, and
the held-connection profiles `connections-1m`, `connections-1m-tls` and
`connections-5m` (CON-1M, CON-1M-TLS, CON-5M).

Every other profile here ranks on one number, requests per second. These
cannot: the rate is pinned, so every entry that finishes serves the same load
and the interesting differences are in what it cost and how the tail behaved.

The score is

    rateFactor = min(1, achieved_rps / 950_000)
    quality    = 0.50*cpuScore + 0.25*p99Score + 0.25*meanScore
    score      = 100 * rateFactor * quality

with, against the best value present in the field:

    cpuScore   = bestCpu / cpu                       (linear)
    p99Score   = 1 - log10(p99  / bestP99 ) / 3      (clamped to 0..1)
    meanScore  = 1 - log10(mean / bestMean)          (clamped to 0..1)

Why the three shapes differ. CPU per request spans about 3.3x across the
entries that hold the rate, so a plain ratio behaves well over it. The p99 tail
spans five orders of magnitude - 151us to 7.6s among rate-holders - and a plain
ratio there collapses to near zero for everything but the leader, spending the
weight without separating anybody; a three-decade scale keeps the field
distinguishable while still charging for a bad tail: ten times the best costs a
third of the term, a thousand times costs all of it.

The mean is the queueing signal. By Little's law it is the number of requests
in flight divided by the rate, so a server that lets requests wait to amortise
its wake-ups shows it here and nowhere else: among entries that answer without
queueing it spans about 2x, and a mean ten times the best means a request spends
nine tenths of its life waiting. That is worth nothing, hence one decade.

p99.9 used to hold the third slot and is still recorded, but no longer scored:
one stall in a twenty-second run moves it a hundredfold (a 166us p99 next to a
25ms p99.9), which at the weight it carried was noise deciding ranks.

The decade spans are fixed rather than derived from the worst entry on purpose,
so one pathological entry joining the board cannot move everybody else's score.
For the same reason nothing is rescaled to make the leader exactly 100: the top
entry scores in the low-to-mid 90s because no single entry is simultaneously
best on cost and on both tails, and that gap is information.

The held-connection profiles score what holding the fleet costs instead:

    rateFactor = min(1, achieved_rps / FULL_RATE[profile])
    quality    = 0.25*cpuScore + 0.25*memScore + 0.25*p50Score + 0.25*p99Score
    score      = 100 * rateFactor * quality

    cpuScore   = bestCpu / cpu                       (linear, CPU per request)
    memScore   = bestMem / mem                       (linear, the server's peak memory)
    p50Score   = 1 - log10(p50 / bestP50) / 3        (clamped to 0..1)
    p99Score   = 1 - log10(p99 / bestP99) / 3        (clamped to 0..1)

A million connections held at one request every four seconds is mostly
waiting, so what separates servers is what the waiting costs: the memory each
connection keeps, the CPU a request carries while the rest of the fleet sits
in the poll set, and how long a request takes when it finally comes - typically
(p50) and in the tail (p99). Memory and CPU spread over a few times, so they
are plain ratios; both latencies get the three-decade scale the p99 has above.
The rate factor still applies: a connection that never opened sends nothing, so
a fleet only partly held shows up as a shortfall in the rate.

CON-RAMP (`connections-ramp-h1`) is not a steady load. Two million connections
open over two minutes, 95% of them idle, and the score is how far the ramp got
before the active connections' p99 went over the limit, as a share of the two
million:

    score = 100 * min(1, reached / FULL_RATE[profile])

`reached` is every connection opened by the last interval that held the limit
(conn_hold.py ramp_summary), idle ones included, whether or not the server has
closed some of them since: closing one is a server doing its job, once it has
kept it 30 seconds (a server that closes them younger ends its own ramp), and is
reported beside it. No ratio against the field's best: the limit is fixed and so
is the target.

Two modes:

    latency_score.py --pick <dir> [--profile P]   best of N runs (benchmark.sh)
    latency_score.py --table [--profile P]        score the published results
"""

from __future__ import annotations
import argparse
import json
import math
import re
import sys
from pathlib import Path

# Full credit at 95% of what was offered. The generator never quite reaches its
# target -- ~998K against 1M is a clean run -- so the threshold has to sit below
# it or nobody would ever earn the whole factor.
FULL_RATE = {
    "latency-1m":  950_000.0,
    "latency-10k":   9_500.0,
    # 8gbit is paced too, so it scores the same way: 95% of its 50K target.
    # Keep in step with LAT_FULL in site/leaderboard/index.html - check_badge_parity.js
    # compares the two and fails the deploy when they disagree.
    "8gbit":     47_500.0,
    # Five million held connections at 1.25M req/s, measured on the window
    # after the fleet is connected: 95% of the target, like the others. A
    # connection that never opened sends nothing, so a fleet only partly held
    # lands here as a rate shortfall.
    "connections-5m":     1_187_500.0,
    # A million held connections at 250K req/s, over TLS or on zrk, scored the
    # same way.
    "connections-1m-tls": 237_500.0,
    "connections-1m": 237_500.0,
    # CON-RAMP is scored on the connections reached, not on a rate: full credit
    # is the whole fleet.
    "connections-ramp-h1": 2_000_000.0,
}
DEFAULT_PROFILE = "latency-1m"
W_CPU, W_P99, W_MEAN = 0.50, 0.25, 0.25
DECADES = 3.0        # p99: a third of the term per decade above the best
MEAN_DECADES = 1.0   # mean: ten times the best is zero

# The held-connection profiles: four equal terms. Keep in step with LAT_HELD
# and latBuild() in site/leaderboard/index.html - check_badge_parity.js runs the
# board's scoring against this one and fails the deploy when ranks disagree.
HELD = frozenset({"connections-1m", "connections-1m-tls", "connections-5m"})
H_CPU, H_MEM, H_P50, H_P99 = 0.25, 0.25, 0.25, 0.25
HELD_DECADES = 3.0   # p50 and p99: a third of the term per decade above the best

# connections-ramp-h1 (CON-RAMP): how many connections the ramp reached within the
# p99 limit, against the whole fleet. Keep in step with LAT_RAMP in
# site/leaderboard/index.html.
RAMP = frozenset({"connections-ramp-h1"})


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


def to_mib(value) -> float | None:
    """'336MiB' / '71.2GiB' / '512KiB' -> MiB, the way mem() in index.html reads
    the memory column. None when unparseable."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    m = re.search(r"([\d.]+)\s*([KMG]i?B)", str(value), re.IGNORECASE)
    if not m:
        return None
    v, u = float(m.group(1)), m.group(2).upper()[0]
    return v * 1024 if u == "G" else v if u == "M" else v / 1024


def _clamp(v: float) -> float:
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def rate_factor(rps: float, full: float) -> float:
    return _clamp(rps / full)


def decade_score(value: float | None, best: float | None,
                 decades: float = DECADES) -> float:
    """1.0 at the best value, falling to 0 over `decades` decades above it."""
    if not value or not best or value <= 0 or best <= 0:
        return 0.0
    return _clamp(1.0 - math.log10(max(value, best) / best) / decades)


def linear_score(value: float | None, best: float | None) -> float:
    if not value or not best or value <= 0 or best <= 0:
        return 0.0
    return _clamp(best / value)


def score_rows(rows: list[dict], profile: str = DEFAULT_PROFILE) -> list[dict]:
    """Annotate rows with their score. Each row needs rps, cpu, p99, mean - and
    mem and p50 on the held-connection profiles, and reached on CON-RAMP.

    Bests are taken over the rows given, so a caller scoring one framework's
    three runs gets them normalised against each other, and a caller scoring the
    board gets them normalised against the field.
    """
    def best_of(key):
        vals = [r[key] for r in rows if r.get(key)]
        return min(vals) if vals else None

    if profile in RAMP:
        for r in rows:
            r["score"] = 100.0 * _clamp((r.get("reached") or 0) / FULL_RATE[profile])
        return rows

    if profile in HELD:
        b_cpu, b_mem = best_of("cpu"), best_of("mem")
        b_p50, b_p99 = best_of("p50"), best_of("p99")
        for r in rows:
            rf = rate_factor(r.get("rps") or 0, FULL_RATE[profile])
            cpu_s = linear_score(r.get("cpu"), b_cpu)
            mem_s = linear_score(r.get("mem"), b_mem)
            p50_s = decade_score(r.get("p50"), b_p50, HELD_DECADES)
            p99_s = decade_score(r.get("p99"), b_p99, HELD_DECADES)
            r["rateFactor"] = rf
            r["cpuScore"], r["memScore"] = cpu_s, mem_s
            r["p50Score"], r["p99Score"] = p50_s, p99_s
            r["score"] = 100.0 * rf * (H_CPU * cpu_s + H_MEM * mem_s + H_P50 * p50_s + H_P99 * p99_s)
        return rows

    b_cpu, b_p99, b_mean = best_of("cpu"), best_of("p99"), best_of("mean")
    for r in rows:
        rf = rate_factor(r.get("rps") or 0, FULL_RATE[profile])
        cpu_s = linear_score(r.get("cpu"), b_cpu)
        p99_s = decade_score(r.get("p99"), b_p99)
        mean_s = decade_score(r.get("mean"), b_mean, MEAN_DECADES)
        r["rateFactor"] = rf
        r["cpuScore"], r["p99Score"], r["meanScore"] = cpu_s, p99_s, mean_s
        r["score"] = 100.0 * rf * (W_CPU * cpu_s + W_P99 * p99_s + W_MEAN * mean_s)
    return rows


def _kv(path: Path) -> dict:
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def pick(dirpath: str, profile: str = DEFAULT_PROFILE) -> int | None:
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
            "mean": to_us(kv.get("avg_lat")),
            # The held-connection profiles also weigh the typical request and
            # the run's peak memory (benchmark.sh writes stats_mem per run).
            "p50": to_us(kv.get("p50_lat")),
            "mem": to_mib(meta.get("stats_mem")),
            # CON-RAMP: how far the ramp got (conn_hold.py ramp_summary).
            "reached": float(kv.get("ramp_reached") or 0),
        })
    if not rows:
        return None
    score_rows(rows, profile)
    return max(rows, key=lambda r: (r["score"], r["rps"]))["run"]


def table(results_dir: Path, profile: str = DEFAULT_PROFILE) -> None:
    rows = []
    for f in sorted(results_dir.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        for key, r in (d.get("results") or {}).items():
            # The exact profile: "connections-1m-" also starts every
            # "connections-1m-tls-..." key.
            if not (key.startswith(profile + "-") and key[len(profile) + 1:].isdigit()):
                continue
            rows.append({
                "fw": d.get("framework", f.stem),
                "rps": r.get("rps") or 0,
                "cpu": r.get("cpu_per_req_us"),
                "p99": to_us(r.get("p99_latency")),
                "mean": to_us(r.get("avg_latency")),
                "p50": to_us(r.get("p50_latency")),
                "mem": to_mib(r.get("memory")),
                "reached": r.get("ramp_reached") or 0,
            })
    if not rows:
        print(f"no {profile} results found", file=sys.stderr)
        return
    score_rows(rows, profile)
    rows.sort(key=lambda r: -r["score"])
    if profile in RAMP:
        print("%-24s %7s %11s %9s %11s %11s" %
              ("framework", "score", "reached", "us/req", "mem MiB", "p99"))
        for r in rows:
            print("%-24s %7.1f %11d %9s %11s %11s" % (
                r["fw"], r["score"], r["reached"],
                "-" if r["cpu"] is None else f"{r['cpu']:.1f}",
                "-" if r["mem"] is None else f"{r['mem']:.0f}",
                "-" if r["p99"] is None else f"{r['p99']:.0f}"))
        return
    if profile in HELD:
        print("%-24s %7s %7s %9s %10s %11s %11s" %
              ("framework", "score", "rate", "us/req", "mem MiB", "p50", "p99"))
        for r in rows:
            print("%-24s %7.1f %7.3f %9s %10s %11s %11s" % (
                r["fw"], r["score"], r["rateFactor"],
                "-" if r["cpu"] is None else f"{r['cpu']:.1f}",
                "-" if r["mem"] is None else f"{r['mem']:.0f}",
                "-" if r["p50"] is None else f"{r['p50']:.0f}",
                "-" if r["p99"] is None else f"{r['p99']:.0f}"))
        return
    print("%-24s %7s %7s %9s %11s %11s" %
          ("framework", "score", "rate", "us/req", "mean", "p99"))
    for r in rows:
        print("%-24s %7.1f %7.3f %9s %11s %11s" % (
            r["fw"], r["score"], r["rateFactor"],
            "-" if r["cpu"] is None else f"{r['cpu']:.1f}",
            "-" if r["mean"] is None else f"{r['mean']:.0f}",
            "-" if r["p99"] is None else f"{r['p99']:.0f}"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pick", metavar="DIR", help="print the winning run number")
    ap.add_argument("--table", action="store_true", help="score published results")
    ap.add_argument("--results", default=None, help="results dir for --table")
    ap.add_argument("--profile", default=DEFAULT_PROFILE, choices=sorted(FULL_RATE),
                    help="which fixed-rate profile to score")
    a = ap.parse_args()
    if a.pick:
        w = pick(a.pick, a.profile)
        if w is None:
            return 1
        print(w)
        return 0
    if a.table:
        root = Path(__file__).resolve().parent.parent
        table(Path(a.results) if a.results else root / "site" / "data" / "results", a.profile)
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
