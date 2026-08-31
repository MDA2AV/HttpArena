---
title: Validation
seo_title: "Latency-1M Benchmark: Validation Checks"
description: "How correctness is established for the Latency-1M fixed-rate CPU profile."
---

This profile has no validation section of its own, and that is not an omission.

It drives `GET /baseline11?a=1&b=2`, the baseline endpoint unchanged, so an entry subscribed to `latency-1m` is run through the full [baseline validation suite](../baseline/validation): the arithmetic, the `Content-Type`, the randomized-input anti-cheat, the TCP fragmentation checks, and the exhaustive per-byte fragmentation sweep. There is no second endpoint to check.

The profile is also unusually hard to game, because the thing an entry would have to fake is not in its control:

- **The load is fixed.** Every entry is offered the same 1,000,000 req/s over the same 1,024 connections for the same 20 seconds. There is no throughput number to inflate.
- **The measurement is taken outside the container.** CPU comes from the kernel's own `cpu.stat` accounting for the container's cgroup, read by the harness. Nothing running inside the container reports it, and nothing running inside can alter it.
- **Serving fewer requests does not help.** The metric is CPU *per request*, so a server that quietly drops load spends less CPU and serves proportionally less, leaving the ratio where it was while `rate_ratio` records that it fell short.

## The one check that is specific to this profile

`rate_ratio`, the achieved rate over the offered rate, is recorded on every run and published with the row.

It is the profile's validity gate rather than a correctness check. A run that did not hold 1,000,000 req/s was not measured under this profile's load, so its CPU figure is not comparable with entries that were. Those runs are flagged rather than ranked as though they were cheap.
