---
title: zrk
seo_title: "zrk: Constant-Throughput Load Generator"
description: "HttpArena uses zrk to hold a fixed offered rate for the fixed-rate profiles (Latency-1M, Latency-10K, Latency-500K/8 and 8Gbit), with coordinated-omission correction and a machine-readable summary."
---

[zrk](https://github.com/zoxy-io/zrk) is a constant-throughput HTTP load generator, used for the fixed-rate profiles: **Latency-1M**, **Latency-10K**, **Latency-500K/8** and **8Gbit**.

## Why a third generator

gcannon and wrk are both closed-loop: each connection sends its next request as soon as the previous response lands, so the rate finds its own ceiling. That answers "how fast can this go", which is what almost every profile here asks.

The fixed-rate profiles ask the opposite question. Latency-1M, for example, pins the rate at one million requests per second and measures what the server spent to serve it, so the generator has to *hold* a rate rather than discover one. gcannon has no rate limiter at all, by design.

## Why zrk and not wrk2

[wrk2](https://github.com/giltene/wrk2) is the original constant-throughput generator and the tool zrk is a rewrite of. Three things decided it:

- **Maintenance.** wrk2's last commit is from September 2019, with over a hundred open issues. zrk is actively developed.
- **Pacing resolution.** wrk2 schedules sends on a millisecond timer wheel, which rounds every wait up and adds roughly half a millisecond of the tool's own noise to every sample. zrk computes a closed-form nanosecond offset instead.
- **Machine-readable output.** `--format json` emits a single summary object, so the harness parses a document rather than scraping a report. That is what makes `rate_ratio` available at all, and `rate_ratio` is the validity gate for each of these profiles.

## Coordinated omission

Latency is measured from the time a request *should* have been sent according to the schedule, not from when it actually went out. A server stall therefore lands in the tail instead of being smoothed away by the client simply sending fewer requests while it recovers.

This is why a run that misses the rate reports latencies in the seconds: the client falls behind its schedule and every queued request carries that lag. It is a correct reading of a server that could not keep up, not an artifact.

## The validity gate

`rate_ratio` is achieved rate over offered rate, and it is published on every row. A run meaningfully below 1.0 did not measure the profile, because the load was not the load, so its CPU figure describes a lighter workload than every other entry's. Those runs are flagged rather than ranked as though they were cheap.

## Version pinning

The image pins an exact version and verifies its checksum, unlike gcannon which tracks its default branch. The premise of the fixed-rate profiles is that the offered load is identical across entries *and across rounds*, so a generator drifting underneath it would invalidate comparisons against numbers already published. Bumping the version is a deliberate act that re-baselines the profiles.

zrk has no distro package. `benchmark.sh` builds the `zrk:local` image from `docker/zrk.Dockerfile` automatically when a framework subscribes to one of these profiles and no `zrk` binary is on the `PATH`.

## Parameters

| Profile | Request | Offered rate | Connections | Duration |
|---|---|---|---|---|
| `latency-1m` | `GET /baseline11?a=1&b=2` | 1,000,000 req/s | 1,024 | 20s |
| `latency-10k` | `GET /baseline11?a=1&b=2` | 10,000 req/s | 1,024 | 20s |
| `latency-500k-8cpu` | `GET /baseline11?a=1&b=2` | 500,000 req/s | 1,024 | 20s |
| `8gbit` | `POST /echo` with a 10 KB body, over TLS on port 8081 | 50,000 req/s | 512 | 5s |

All of them run with 64 threads and 3 runs, keeping the run with the best score.
