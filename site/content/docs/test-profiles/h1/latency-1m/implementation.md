---
title: Implementation Guidelines
seo_title: "Latency-1M Benchmark: Implementation Guide"
description: "What to implement, what is measured, and how the fixed-rate CPU profile at one million requests per second is scored."
---
{{< type-rules standard="Nothing to implement - the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. What it asks of you is a serving model that does not spend CPU it is not using: no busy-wait loop, no spin-poll on a ring, no timer thread waking at a fixed frequency to find nothing to do. All of those are charged here and no other profile can see them." tuned="May tune poll intervals, batching, affinity and ring sizing freely. Note that submission-queue polling and every other spin mode is charged in full: it buys latency at a fixed CPU price, and this is the one profile that prices that trade rather than rewarding it." engine="Same as above, and it matters more: an engine with a fixed worker pool polling at a set cadence spends the same CPU at one million req/s as it does at ten thousand, which this profile is designed to expose. Configuration that scales the poll to the load is in scope; a build that cannot idle is a real result, not a disqualification." >}}


Every other profile drives a server until it stops and reports where that was. This one fixes the load and reports the bill. **The rate is one million requests per second**, paced and constant - not a target to beat. Every entry that completes serves the same million; only the CPU spent differs.

**Endpoint:** `GET /baseline11?a=1&b=2` · **Connections:** 1,024 · **Rate:** 1,000,000 req/s · **Duration:** 20s

## Nothing to implement

The load is `GET /baseline11?a=1&b=2` - the same endpoint the [baseline profile](../baseline/implementation) already specifies and validates, GET only, no request bodies. **If your entry subscribes to `baseline`, subscribing here costs no code.**

The handler is deliberately as thin as the framework allows, so what is left in the CPU figure is the framework's own overhead: accept loop, event loop, parser, router, response path.

## What is measured

CPU time the server's container actually consumed, read from cgroup v2 `cpu.stat` `usage_usec` immediately before and after the load window - a monotonic kernel counter, exact to the microsecond, not sampled.

| field | meaning |
|---|---|
| `cpu_usec` | total CPU microseconds across the run |
| `cpu_per_req_us` | the same divided by requests served - the metric this profile ranks on |

A result only counts if the rate was delivered. `rate_ratio` (achieved over target) ships with every row; a run meaningfully below 1.0 measured a lighter workload than everyone else and is flagged rather than ranked as cheap.

## Implementation notes

- **Do not busy-wait.** A spin loop, a submission-queue poller, or a worker that never sleeps costs a full core whether it is serving a million requests per second or none. That is a real trade - it buys latency - and this is the one profile that prices it instead of rewarding it
- **Watch fixed-cadence timers.** A background thread waking every millisecond to find no work spends measurable CPU doing nothing, a thousand times a second
- **Per-connection state is charged here.** 1,024 connections holding large per-connection buffers cost memory, and allocating and touching it costs CPU
- **Garbage collection lands in the number.** A collector running at this rate is genuinely spending the machine. Three runs keeps startup allocation out; steady-state collection correctly stays in

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body) |
| Offered rate | 1,000,000 req/s, paced |
| Connections | 1,024 |
| Duration | 20s |
| Runs | 3, and the **highest-scoring** one is kept |
| Load generator | [zrk](/docs/load-generators/h1/zrk/) (constant throughput, coordinated-omission corrected) |
| Metric | CPU microseconds per request, from cgroup `cpu.stat` |

## Scoring

The rate is pinned, so throughput is identical by construction and cannot rank anything. The score combines what it cost with how the tail behaved.

```
rateFactor = min(1, achieved_rps / 950,000)
quality    = 0.60 x cpuScore + 0.25 x p99Score + 0.15 x p999Score
score      = 100 x rateFactor x quality
```

each term measured against the best value present in the field, clamped to 0-1:

| term | shape | at the best | 10x worse | 100x worse | 1000x worse |
|---|---|---|---|---|---|
| `cpuScore` | `bestCpu / cpu` | 1.00 | 0.10 | 0.01 | 0.00 |
| `p99Score` | `1 - log10(p99 / bestP99) / 3` | 1.00 | 0.67 | 0.33 | 0.00 |
| `p999Score` | `1 - log10(p999 / bestP999) / 3` | 1.00 | 0.67 | 0.33 | 0.00 |

The two shapes differ because the quantities do: CPU per request spans about 3.3x across rate-holders, where a plain ratio behaves; the tails span five orders of magnitude, where a ratio would collapse to near zero for everyone but the leader and spend 40% of the weight without separating anybody.

`rateFactor` is the gate: full credit at 950,000 and above, falling proportionally below it, so a server that quietly serves less cannot look cheap. Nothing is rescaled so the leader lands on exactly 100 - no entry is simultaneously best on cost and both tails, and that gap is information.

On the composite board the score is shown x10, on the 0-1,000 basis every profile column uses. Computed by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py), mirrored in the board's JavaScript; run `python3 scripts/latency_score.py --table --profile latency-1m` for the published results.
