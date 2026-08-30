---
title: Implementation Guidelines
seo_title: "Latency-1M Benchmark: Implementation Guide"
description: "How the one-million-requests-per-second fixed-rate CPU profile is run, what it measures, and the type-specific rules that apply to it."
---
{{< type-rules standard="Nothing to implement - the profile drives `GET /baseline11`, which the baseline profile already specifies and validates. What it asks of you is a serving model that does not spend CPU it is not using: no busy-wait loop, no spin-poll on a ring, no timer thread waking at a fixed frequency to find nothing to do. All of those are charged here and no other profile can see them." tuned="May tune poll intervals, batching, affinity and ring sizing freely. Note that submission-queue polling and every other spin mode is charged in full: it buys latency at a fixed CPU price, and this is the one profile that prices that trade rather than rewarding it." engine="Same as above, and it matters more: an engine with a fixed worker pool polling at a set cadence spends the same CPU at one million req/s as it does at ten thousand, which this profile is designed to expose. Configuration that scales the poll to the load is in scope; a build that cannot idle is a real result, not a disqualification." >}}


Every other profile here drives a server until it stops and reports where that was. This one fixes the load and reports the bill.

**The rate is one million requests per second**, offered at a paced, constant rate. It is not a target to be beaten. Every entry that completes the run serves exactly the same million requests. The only thing that varies is the CPU each one burned doing it.

**Connections:** 1,024 · **Rate:** 1,000,000 req/s · **Duration:** 20s

## There is an entry fee

A million requests per second is not a load every framework on this board can take. At the time of writing, **46 of 103** enabled entries with a published baseline number can reach a million at all, and reaching it means running flat out with nothing left. Only the 19 entries above two million have genuine headroom at this rate.

That is the profile's shape, not an accident of tuning. It is a high-water-mark test: among the entries fast enough that a million requests per second is comfortable, which of them is *cheap*. Two frameworks can post the same ceiling on `baseline` and spend very different amounts of machine getting to a fixed fraction of it, and nothing else here would tell you which.

An entry that cannot hold the rate is not failed for it. It is flagged instead, because its number then describes a lighter workload than everyone else's. See [Validity](#validity-the-rate-has-to-have-been-delivered) below.

## Nothing to implement

The load is `GET /baseline11?a=1&b=2`, the same endpoint the [baseline profile](../baseline/implementation) specifies, with the same response, and only ever the GET. The mixed GET/POST/chunked rotation belongs to `baseline`; there are no request bodies here at all.

If your entry already subscribes to `baseline`, subscribing to `latency-1m` costs you no code.

That thinness is deliberate. The handler is as small as the framework allows, so what is left in the CPU figure is the framework's own overhead (accept loop, event loop, parser, router, response path) rather than anything the workload contributed.

## What is measured

The number is the **CPU time the server's container actually consumed**, taken from cgroup v2's `cpu.stat` `usage_usec` immediately before and after the load window. That counter is kept by the kernel and is monotonic, so the difference is exact to the microsecond.

It is reported two ways:

| field | meaning |
|---|---|
| `cpu_usec` | total CPU microseconds consumed across the run |
| `cpu_per_req_us` | the same figure divided by requests served, and the metric this profile ranks on |

Every other profile reports CPU as a percentage averaged from `docker stats` samples taken about twice a second. That is fine where CPU is context for a throughput number. It is not fine where CPU *is* the number: a 20s run yields only ~40 samples, and each one is whatever the container happened to be doing at that instant. Nothing here is sampled.

## Connections are part of the workload

A million requests per second at sub-millisecond latency needs only a few dozen requests in flight. The profile holds **1,024** connections anyway.

The rest are not there to carry load, they are there to be *managed*: registered with the event loop, polled, kept alive, holding whatever per-connection state the framework allocates. That management is a cost a server pays whether or not the connections are busy, and it is the cost a real server pays all day. Measuring with only the connections strictly needed would measure a machine nobody runs.

## Validity: the rate has to have been delivered

A fixed-rate result only means something if the rate was actually offered and served. The load generator reports `rate_ratio`, which is achieved over target, and it is published with every row.

A run with `rate_ratio` meaningfully below 1.0 did not measure this profile: the load was not the load, so its CPU figure describes a lighter workload than the one every other entry was measured on. Those runs are flagged rather than silently ranked as though they were cheap.

## The load generator

This profile is driven by [zrk](https://github.com/zoxy-io/zrk) rather than gcannon, because gcannon does not pace. It has no rate limiter, by design: it was built to find ceilings.

zrk is a Zig rewrite of [wrk2](https://github.com/giltene/wrk2), the original constant-throughput generator, and is used here in preference to it for three reasons: wrk2's last commit is from 2019; zrk schedules sends on a closed-form nanosecond offset rather than wrk2's millisecond timer wheel, which rounds every wait up and adds about half a millisecond of the tool's own noise to every sample; and zrk emits a JSON summary, so the harness parses a document instead of scraping a report.

Its version is pinned with a checksum. The premise of this profile is that the offered load is identical across entries and across rounds, so a generator that drifts underneath it would invalidate comparisons against numbers already published.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /baseline11?a=1&b=2` (GET only, no body) |
| Offered rate | 1,000,000 req/s, paced |
| Connections | 1,024 |
| Duration | 20s |
| Runs | 3, and the **highest-scoring** one is kept |
| Load generator | zrk (constant throughput, coordinated-omission corrected) |
| Metric | CPU microseconds per request, from cgroup `cpu.stat` |

Three runs are taken and the best of them is kept, judged by the same formula described under [Scoring](#scoring). Since every run delivers the same rps by construction, keeping the fastest would be choosing between them at random. Scoring them also discards the warm-up for free: an unsettled JIT, or a GC heap that has not reached steady state, shows up precisely as CPU, and the first run is the one carrying it.

## Implementation notes

- **Do not busy-wait.** A spin loop, a submission-queue poller, or a worker that never sleeps costs a full core whether it is serving a million requests per second or none. That is a real trade, since it buys latency, and this is the one profile that prices it instead of rewarding it
- **Watch fixed-cadence timers.** A background thread that wakes every millisecond to check for work spends measurable CPU doing nothing, a thousand times a second, forever
- **Per-connection state is charged here.** 1,024 connections holding large per-connection buffers cost memory, and allocating and touching that memory costs CPU
- **Garbage collection lands in the number.** This is not a distortion; a collector running at a million requests per second is genuinely spending the machine. Three runs and lowest-wins keeps startup allocation out of it, while steady-state collection correctly stays in

## Scoring

Every other profile ranks on one number, requests per second. This one cannot: the rate is pinned, so every entry that finishes serves the same load and throughput is identical by construction. The score combines what it cost with how the tail behaved.

```
rateFactor = min(1, achieved_rps / 950,000)
quality    = 0.60 x cpuScore + 0.25 x p99Score + 0.15 x p999Score
score      = 100 x rateFactor x quality
```

measured against the best value present in the field:

| term | shape | at the best | 10x worse | 100x worse | 1000x worse |
|---|---|---|---|---|---|
| `cpuScore` | `bestCpu / cpu` | 1.00 | 0.10 | 0.01 | 0.00 |
| `p99Score` | `1 - log10(p99 / bestP99) / 3` | 1.00 | 0.67 | 0.33 | 0.00 |
| `p999Score` | `1 - log10(p999 / bestP999) / 3` | 1.00 | 0.67 | 0.33 | 0.00 |

All three are clamped to 0–1.

**Why the two shapes differ.** CPU per request spans about 3.3x across the entries that hold the rate, so a plain ratio behaves well over it. The latency tails span five orders of magnitude, 151 µs to 7.6 s at p99 among rate-holders, and a plain ratio there collapses to near zero for everything but the leader, spending 40% of the weight without separating anybody. A decade scale keeps the whole field distinguishable while still charging heavily for a bad tail.

**Why the 3-decade span is fixed** rather than derived from the worst entry: one pathological entry joining the board would otherwise move everybody else's score.

**`rateFactor` is the gate.** Full credit at 950,000 req/s and above. The practical ceiling is around 998,000, so everything that holds the rate sits comfortably clear of it. Below that it falls proportionally, so an entry serving 50,000 req/s keeps `50/950 ≈ 0.053` of whatever quality it earned. This is what stops a server that quietly serves less from looking cheap: its CPU per request may be excellent, but it is multiplied by a rate factor near zero.

**Nothing is rescaled so the leader lands on exactly 100.** The top entry scores in the low-to-mid 90s because no single entry is simultaneously best on cost and on both tails, and that gap is information. It also means a score means the same thing across rounds instead of being silently rebased whenever a new leader arrives.

**Best of three runs** is decided by this same formula, with each metric normalised against the best of that entry's own three runs rather than against the field, which does not exist yet while one entry is being measured. Choosing on CPU alone could keep a cheap run with a wrecked tail.

On the composite board this score is shown ×10, on the 0–1,000 basis every
profile column uses there. The detail view and `--table` report it as defined
above, out of 100.

The reference implementation is [`scripts/latency_1m_score.py`](https://github.com/MDA2AV/HttpArena/blob/main/scripts/latency_1m_score.py); the board mirrors it in JavaScript. Run `python3 scripts/latency_1m_score.py --table` to score the published results from the command line.

### Composite

This profile **counts toward the composite score**, for framework and engine entries alike.

It is the one profile the composite does not normalize on requests per second, because it cannot: the rate is pinned, so every entry that holds it delivers the same one and rps would score them all identically. The score above is contributed directly, multiplied by 10 onto the composite's 0–1,000 per-profile scale.

Because that score is not rebased on the field leader, the best entry here contributes about 970 rather than a full 1,000, because nobody is simultaneously cheapest and best on both tails. That is the same deliberate choice as above, carried through to the sum.
