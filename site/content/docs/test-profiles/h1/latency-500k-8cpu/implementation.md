---
title: Implementation Guidelines
seo_title: "Latency-500K/8 Benchmark: Implementation Guide"
description: "What to implement, what is measured, and how the fixed-rate CPU profile at 500,000 requests per second on four cores plus SMT is scored."
---
{{< type-rules standard="Nothing to implement - the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. What it asks of you is a serving model whose cost per request stays flat when the machine is busy: on eight logical CPUs at 500K req/s there is little spare capacity to hide a wake-up in, so every syscall, allocation and context switch on the request path is charged, and every request left waiting to amortise them is charged to the mean." tuned="May tune poll intervals, batching, affinity and ring sizing freely. Spin modes are charged in full here as on Latency-1M, and with four cores they are charged out of the same budget the requests need." engine="Same as above. An engine that pins one event loop per logical CPU gets eight of them; one that sizes its pool from the host rather than the cpuset will oversubscribe, and the scheduling shows in both the CPU and the mean." >}}


[Latency-1M](../latency-1m/implementation/) offers one million requests per second to thirty-two cores, a load that sits at a quarter of the fastest entries' capacity. At that utilisation every thin server pays the same per-wakeup floor - the eight cheapest entries land within 2 µs of each other - and the only way below it is to let requests queue and handle several per wake-up. This profile removes the headroom instead. **The rate is 500,000 req/s and the server gets four cores with both SMT threads**, so the load sits near saturation for most entries, the marginal cost of a request is what the CPU figure reports, and the queue a server builds to keep up is what its mean latency reports.

**Endpoint:** `GET /baseline11?a=1&b=2` · **CPU:** cpuset `0-3,64-67` (four cores, both threads) · **Rate:** 500,000 req/s · **Connections:** 1,024 · **Duration:** 20s

## Nothing to implement

The load is `GET /baseline11?a=1&b=2` - the same endpoint the [baseline profile](../baseline/implementation) already specifies and validates, GET only, no request bodies. **If your entry subscribes to `baseline`, subscribing here costs no code.**

The cpuset is the only thing that is new, and it is applied from outside: the container is started with `--cpuset-cpus=0-3,64-67`, so a runtime that sizes its thread pool from the cgroup's CPU count sees eight and one that reads the host's count sees a hundred and twenty-eight. The second kind will oversubscribe four cores by a wide margin, which is a real result rather than a setup error.

## What is measured

CPU time the server's container consumed, read from cgroup v2 `cpu.stat` `usage_usec` immediately before and after the load window, exactly as on Latency-1M, plus the coordinated-omission-corrected mean and p99 latency.

| field | meaning |
|---|---|
| `cpu_usec` | total CPU microseconds across the run |
| `cpu_per_req_us` | the same divided by requests served |
| `avg_latency` | mean latency from the scheduled send - by Little's law, the requests in flight over the rate |
| `rate_ratio` | achieved over offered; below 0.95 the run measured a lighter load than everyone else's |

Two things read differently here than at 1M on thirty-two cores:

- **The CPU figure cannot be amortised away.** With eight logical CPUs at 500K req/s there is little idle capacity to take a wake-up on, so a server that queues to batch requests per wake-up gains less than it does at 1M and pays for it in the mean
- **Holding the rate is not a given.** Entries whose four-core ceiling sits below 500K fall through `rateFactor`; that is the profile working as intended, not a failed run

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body) |
| Offered rate | 500,000 req/s, paced |
| CPU | cpuset `0-3,64-67`: four cores and their SMT siblings |
| Connections | 1,024 |
| Duration | 20s |
| Runs | 3, and the highest-scoring one is kept |
| Load generator | [zrk](/docs/load-generators/h1/zrk/) (constant throughput, coordinated-omission corrected) |
| Metric | CPU microseconds per request, from cgroup `cpu.stat`, with the mean and p99 latency |

## Scoring

Identical in form to [Latency-1M's](../latency-1m/implementation/#scoring), with the rate threshold moved:

```
rateFactor = min(1, achieved_rps / 475,000)
quality    = 0.50 x cpuScore + 0.25 x p99Score + 0.25 x meanScore
score      = 100 x rateFactor x quality
```

Full credit at 475,000 req/s, 95% of the rate offered. Computed by [`scripts/latency_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_score.py); run `python3 scripts/latency_score.py --table --profile latency-500k-8cpu` for the published results.

**Reference-only for now.** The profile is measured and shown but does not enter any composite score while the first entries are being measured and the rate and cpuset are confirmed on the bench host.
