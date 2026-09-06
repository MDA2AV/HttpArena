---
title: Validation
seo_title: "Latency-500K/4 Benchmark: Validation Checks"
description: "How correctness is established for the Latency-500K/4 fixed-rate CPU profile."
---

This profile has no validation section of its own, and that is not an omission.

It drives `GET /baseline11?a=1&b=2`, the baseline endpoint unchanged, so an entry subscribed to `latency-500k-4cpu` is run through the full [baseline validation suite](../baseline/validation): the arithmetic, the `Content-Type`, the randomized-input anti-cheat, the TCP fragmentation checks, and the exhaustive per-byte fragmentation sweep. There is no second endpoint to check.

The profile is as hard to game as [Latency-1M](../latency-1m/validation), for the same reasons: the load is fixed, the CPU is read by the harness from the container's cgroup rather than reported from inside it, and serving fewer requests leaves CPU per request where it was while `rate_ratio` records the shortfall.

## The one check that is specific to this profile

`rate_ratio`, the achieved rate over the offered rate, is recorded on every run and published with the row. It is the profile's validity gate rather than a correctness check: on two cores a run that did not hold 500,000 req/s was not measured under this profile's load, so its CPU figure is not comparable with entries that were, and the score falls proportionally with it.
