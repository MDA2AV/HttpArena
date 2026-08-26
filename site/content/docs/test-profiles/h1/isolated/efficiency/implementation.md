---
title: Implementation Guidelines
seo_title: "CPU Efficiency Benchmark — Implementation Guide"
description: "How the fixed-throughput CPU efficiency profile is run, what it measures, and the type-specific rules that apply to it."
---
{{< type-rules standard="Nothing to implement - the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. What it asks of you is a serving model that idles: no busy-wait loop, no spin-poll on a ring, no timer thread waking at a fixed frequency to find nothing to do. All of those cost CPU that this profile charges you for and no other profile here can see." tuned="May tune poll intervals, batching, affinity and ring sizing freely. Note that submission-queue polling and any other spin mode is charged in full here: it buys latency at a fixed CPU cost, and this is the one profile that prices that trade rather than rewarding it." engine="Same as above, and it matters more: an engine with a fixed worker pool that polls at a set cadence spends the same CPU at 500K req/s as it does at 5M, which this profile is designed to expose. Configuration that scales the poll to the load is in scope; a build that cannot idle is a real result, not a disqualification." >}}


The Efficiency profile pins the offered load and measures the cost.

Every other HTTP/1.1 profile here drives a server to saturation and reports where it stopped. That answers "what is the ceiling", which matters when you are sizing for a peak. It says nothing about the other 99% of a server's life, which is spent far below that ceiling — and two frameworks with the same ceiling can burn very different amounts of CPU getting to the same modest number.

So this profile fixes the rate at **500,000 requests per second**, which every entry that reaches the profile can serve, and reports what each one spent to serve it.

**Connections:** 1,024 · **Rate:** 500,000 req/s · **Duration:** 20s

## Nothing to implement

The load is `GET /baseline11?a=1&b=2` — the same endpoint the [baseline profile](../baseline/implementation) specifies, with the same response. If your entry already subscribes to `baseline`, subscribing to `efficiency` costs you no code at all.

That is deliberate. The handler is as thin as the framework allows, so what is left in the CPU figure is the framework's own overhead — accept loop, event loop, parser, router, response path — rather than anything the workload contributed.

## What is measured

The number is the **CPU time the server's container actually consumed**, taken from cgroup v2's `cpu.stat` `usage_usec` immediately before and after the load window. That counter is maintained by the kernel and is monotonic, so the difference is exact to the microsecond.

It is reported two ways:

| field | meaning |
|---|---|
| `cpu_usec` | total CPU microseconds consumed across the run |
| `cpu_per_req_us` | the same figure divided by requests served — **the profile's metric** |

Every other profile reports CPU as a percentage averaged from `docker stats` samples taken about twice a second. That is fine where CPU is context for a throughput number. It is not fine where CPU *is* the number: a 20s run yields only ~40 samples and each one is whatever the container happened to be doing at that instant. Nothing here is sampled.

## Connections are part of the workload

500,000 req/s at sub-millisecond latency needs only about 15 requests in flight. The profile holds **1,024** connections anyway.

The other 1,000-odd are not there to carry load, they are there to be *managed* — registered with the event loop, polled, kept alive, held in whatever per-connection state the framework allocates. That management is a real cost that a server pays whether or not the connections are busy, and it is exactly the cost a mostly-idle production server pays all day. Measuring at 16 connections would measure a machine no one runs.

## Validity: the rate has to have been delivered

A fixed-rate result only means something if the rate was actually offered and served. The load generator reports `rate_ratio` — achieved over target — and it is published with every row.

A run with `rate_ratio` meaningfully below 1.0 did not measure this profile: the load was not the load, so its CPU figure describes a lighter workload than the one every other entry was measured on. Those runs are flagged rather than silently ranked.

## The load generator

This profile is driven by [zrk](https://github.com/zoxy-io/zrk) rather than gcannon, because gcannon does not pace — it has no rate limiter, by design, being built to find ceilings.

zrk is a Zig rewrite of [wrk2](https://github.com/giltene/wrk2), the original constant-throughput generator, and is used here in preference to it for three reasons: wrk2's last commit is from 2019; zrk schedules sends on a closed-form nanosecond offset rather than wrk2's millisecond timer wheel, which rounds every wait up and adds about half a millisecond of the tool's own noise to every sample; and zrk emits a JSON summary, so the harness parses a document instead of scraping a report.

Its version is pinned with a checksum. The premise of this profile is that the offered load is identical across entries and across rounds, so a generator that drifts underneath it would invalidate comparisons against numbers already published.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` |
| Offered rate | 500,000 req/s, paced |
| Connections | 1,024 |
| Duration | 20s |
| Runs | 3 — the **cheapest** is kept, not the fastest |
| Load generator | zrk (constant throughput, coordinated-omission corrected) |
| Metric | CPU microseconds per request, from cgroup `cpu.stat` |

Three runs are taken and the one with the lowest CPU wins. Since every run delivers the same rps by construction, keeping the fastest would be choosing between them at random — and keeping the cheapest discards the warm-up for free, because an unsettled JIT or a GC heap that has not reached steady state shows up precisely as CPU, and the first run is the one carrying it.

## Implementation notes

- **Do not busy-wait.** A spin loop, a submission-queue poller, or a worker that never sleeps costs a full core whether it is serving 500,000 requests per second or none. That is a real trade — it buys latency — and this is the one profile that prices it instead of rewarding it
- **Watch fixed-cadence timers.** A background thread that wakes every millisecond to check for work spends measurable CPU doing nothing, 1,000 times a second, forever
- **Per-connection state is charged here.** 1,024 connections holding large per-connection buffers cost memory, and the allocation and touching of that memory costs CPU
- **Garbage collection lands in the number.** This is not a distortion; a collector that runs at 500,000 req/s is genuinely spending the machine's CPU. Three runs and lowest-wins keeps startup allocation out of it, but steady-state collection stays in, correctly

## Scoring

This profile is currently **reference-only**: it is measured, published and shown, but it does not contribute to the composite score ([#1310](https://github.com/MDA2AV/HttpArena/issues/1310)).

Unlike the other unscored profiles, this one cannot simply be switched on. The composite sums normalized requests-per-second, and this profile's metric is CPU, where lower is better — scoring it means teaching the composite a lower-is-better metric first, not flipping a flag.
