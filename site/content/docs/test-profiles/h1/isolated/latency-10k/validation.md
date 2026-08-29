---
title: Validation
seo_title: "Latency-10K Benchmark: Validation Checks"
description: "How correctness is established for the Latency-10K fixed-rate CPU profile."
---

This profile adds no endpoint of its own.

It drives `GET /baseline11?a=1&b=2`, the baseline endpoint unchanged, so an entry subscribed to `latency-10k` is run through the full [baseline validation suite](../baseline/validation): the arithmetic, the `Content-Type`, the randomized-input anti-cheat, the TCP fragmentation checks, and the exhaustive per-byte fragmentation sweep. There is no second endpoint to check.

What the profile adds is a *measurement* gate rather than a correctness one. `rate_ratio` - achieved rps over offered rps - is published with every result, and an entry that did not hold the offered rate is not comparable on CPU with one that did. See [Validity](../implementation/#validity) on the implementation page.
