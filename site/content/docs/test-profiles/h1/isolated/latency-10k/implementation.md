---
title: Implementation Guidelines
seo_title: "Latency-10K Benchmark: Implementation Guide"
description: "How the 10,000 requests per second near-idle fixed-rate CPU profile is run, what it measures, and the type-specific rules that apply to it."
---
{{< type-rules standard="Nothing to implement: the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. What it asks of you is that your serving model is quiet when there is nothing to do. A framework that polls on a timer, spins a worker between requests, or wakes every thread on every arrival pays for it here in a way a saturated benchmark hides." tuned="May tune poll intervals, spin thresholds, affinity and pool sizing freely. Note that a busy-poll setting chosen to win a saturation benchmark is charged here rather than rewarded: CPU burned while idle is exactly what this profile reports." engine="Same as above. An engine that busy-polls its completion queue will show a large fixed cost at this rate; one that blocks until work arrives will not." >}}


[Latency-1M](../latency-1m/implementation/) asks what a server costs at a load only the fastest entries carry. This asks what the same server, on the same cores, costs when it is nearly idle.

The load is **10,000 requests per second**, offered at a paced constant rate. Everything else is Latency-1M's setup unchanged.

**CPU:** cpuset `0-31,64-95` · **Rate:** 10,000 req/s · **Connections:** 1,024 · **Duration:** 20s

## Only the rate changes

The two profiles share their cpuset, connection count, endpoint, duration and load generator. That is deliberate and it is the whole design: with a single variable, the two published numbers are directly comparable, and the difference between them is attributable to load rather than to setup.

At 10,000 req/s spread over 64 hardware threads the request work is close to nothing. What is left in the CPU figure is the **standing cost** - the price of being a running server rather than of serving this particular load:

- poll loops and spin thresholds that never sleep
- timer wheels and keep-alive sweeps that tick regardless of traffic
- background GC, JIT and runtime threads
- a wake-up path that touches more threads than the one request needs

A saturated box amortises all of that across a million requests a second until it disappears into the noise. Here it is most of the number.

## Nothing to implement

The load is `GET /baseline11?a=1&b=2`, the same endpoint the [baseline profile](../baseline/implementation) specifies, GET only and no request body. If your entry already subscribes to `baseline`, subscribing to `latency-10k` costs you no code.

## What is measured

Exactly what Latency-1M measures, by the same means: the CPU the container consumed, taken from cgroup v2's `cpu.stat` `usage_usec` either side of the load window, reported as `cpu_usec` and as `cpu_per_req_us`, plus the p99 and p99.9 service latencies. Nothing is sampled.

Latency matters here for a different reason than it does at 1M. With 1,024 connections and 10,000 requests per second there is no queueing to speak of, so a tail is not congestion - it is a scheduler that took its time waking the right thread, a GC pause, or a timer that fired late. The tails at this rate read as responsiveness from idle rather than as capacity.

## Reading it against Latency-1M

Per-request CPU is not comparable between the two profiles, and it is not meant to be. At a million requests per second a large share of the per-request cost is contention - cache lines moving between cores, the socket table, the scheduler - which a near-idle server never pays. Expect this profile's per-request figure to be *higher*, not lower: the standing cost is divided across a hundredth of the requests.

The two are scored independently and should be read that way. The interesting comparison is between entries at the same rate, not between rates.

## What it exposes

- **Busy-polling.** A runtime that spins rather than blocking burns whole cores here while serving almost nothing, and the CPU figure says so plainly.
- **Fixed-cost runtimes.** A background GC thread, a JIT compiler thread or a millisecond timer is a rounding error at 1M req/s and a large share of the bill at 10K.
- **Oversized thread pools.** Threads that never run still cost scheduling, stacks and wake-ups.
- **Wake-up amplification.** A design that wakes every worker on every arrival is invisible under saturation, where they all had work anyway, and expensive when they did not.

## Validity

`rate_ratio` is still the gate, though it should be uncontroversial at this rate: an entry that cannot hold 10,000 requests per second across 64 threads has a problem this profile is not the right place to diagnose. It is published for every result all the same, because the arithmetic that makes a saturated entry look good on CPU applies at any rate - a server that serves fewer requests spends proportionally less CPU on each, so a per-request figure can look better while the entry is failing.

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

Full credit at 9,500 req/s, which is 95% of the offered rate. The generator never quite reaches its own target, so the threshold sits below it.

Both profiles are scored by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py); run `python3 scripts/latency_score.py --table --profile latency-10k` to score the published results.

### Composite

**Reference-only for now**: measured, published and shown, but not contributing to the composite score until the rate has been shown board-wide to be the right one. Every profile here has started that way.
