---
title: Implementation Guidelines
seo_title: "Latency-10K Benchmark: Implementation Guide"
description: "What to implement, what is measured, and how the near-idle fixed-rate CPU profile at 10,000 requests per second is scored."
---
{{< type-rules standard="Nothing to implement: the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. What it asks of you is that your serving model is quiet when there is nothing to do. A framework that polls on a timer, spins a worker between requests, or wakes every thread on every arrival pays for it here in a way a saturated benchmark hides." tuned="May tune poll intervals, spin thresholds, affinity and pool sizing freely. Note that a busy-poll setting chosen to win a saturation benchmark is charged here rather than rewarded: CPU burned while idle is exactly what this profile reports." engine="Same as above. An engine that busy-polls its completion queue will show a large fixed cost at this rate; one that blocks until work arrives will not." >}}


[Latency-1M](../latency-1m/implementation/) asks what a server costs at a load only the fastest entries carry. This asks what the same server, on the same cores, costs when it is nearly idle. **Only the rate changes** - cpuset, connections, endpoint, duration and generator are Latency-1M's, unchanged, so the two numbers are directly comparable and the difference is attributable to load rather than setup.

**Endpoint:** `GET /baseline11?a=1&b=2` · **CPU:** cpuset `0-31,64-95` · **Rate:** 10,000 req/s · **Connections:** 1,024 · **Duration:** 20s

## Nothing to implement

The same endpoint the [baseline profile](../baseline/implementation) already specifies and validates, GET only, no request body. **If your entry subscribes to `baseline`, subscribing here costs no code.**

## What is measured

The CPU the container consumed, from cgroup v2 `cpu.stat` `usage_usec` either side of the load window - reported as `cpu_usec` and `cpu_per_req_us` - plus p99 and p99.9 latency. Nothing is sampled.

At 10,000 req/s spread over 64 hardware threads the request work is close to nothing, so what the figure reports is the **standing cost** of being a running server. That is what to look at when optimising for this profile:

- **Busy-polling.** A runtime that spins rather than blocking burns whole cores here while serving almost nothing
- **Fixed-cadence timers.** Timer wheels and keep-alive sweeps that tick regardless of traffic
- **Background runtime threads.** GC and JIT threads are a rounding error at 1M req/s and a large share of the bill at 10K
- **Oversized thread pools.** Threads that never run still cost scheduling, stacks and wake-ups
- **Wake-up amplification.** Waking every worker on every arrival is invisible under saturation, where they all had work anyway, and expensive when they did not

Tails read differently here than at 1M: with no queueing to speak of, a tail is not congestion but a scheduler that took its time waking the right thread, a GC pause, or a timer that fired late.

**Per-request CPU is not comparable between the two profiles and is not meant to be.** Expect this one to be *higher* - the standing cost is divided across a hundredth of the requests. Compare entries at the same rate, not rates against each other.

`rate_ratio` is still published as the validity gate, though it should be uncontroversial at this rate.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body) |
| Offered rate | 10,000 req/s, paced |
| CPU | cpuset `0-31,64-95`, the same as Latency-1M |
| Connections | 1,024 |
| Duration | 20s |
| Runs | 3, and the highest-scoring one is kept |
| Load generator | [zrk](/docs/load-generators/h1/zrk/) |
| Metric | CPU microseconds per request, from cgroup `cpu.stat` |

## Scoring

Identical in form to [Latency-1M's](../latency-1m/implementation/#scoring), with the rate threshold moved:

```
rateFactor = min(1, achieved_rps / 9,500)
quality    = 0.60 x cpuScore + 0.25 x p99Score + 0.15 x p999Score
score      = 100 x rateFactor x quality
```

Full credit at 9,500 req/s, 95% of the rate offered. Computed by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py); run `python3 scripts/latency_score.py --table --profile latency-10k` for the published results.

Scored for framework entries (flagship, emerging, experimental) and for engines; not for infrastructure, matching Latency-1M - no proxy is measured on either profile yet.
