---
title: Validation
seo_title: "Async Delay Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the async delay benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `async` test.

None of them care *how* the wait was implemented. Blocking the request's thread is a permitted implementation on this profile - it is meant to lose the benchmark, not to fail validation - so every timing assertion here is a lower bound on a single response, never a bound on total throughput or on wall time.

## Randomized delay

Sends `GET /delay/{ms}` with `{ms}` drawn fresh between 10 and 90. Verifies:

- the response is `200`
- the body is the requested number
- the response did not arrive before the requested delay had elapsed

Because the value is chosen after the container is up, nothing prepared at startup can answer it. The benchmark itself asks for a flat 15 ms, so this section carries all of the anti-cheat weight for the parameter.

## Content-Type header

Verifies the `Content-Type` response header is `text/plain`.

## Zero delay

Sends `GET /delay/0` and verifies the body is `0`. Zero is a delay of zero, not a missing parameter; an implementation that treats a falsy value as absent and substitutes a default answers with the wrong number here.

## The delay tracks the parameter

Sends `GET /delay/10` and `GET /delay/500` and requires the second to take at least 300 ms longer than the first.

Echoing the parameter back in the body proves it was parsed. This proves it reached the sleep. An implementation that returns the right number after a fixed wait passes every other check in this section and fails this one.

## Not a constant long sleep

Requires `GET /delay/10` to complete within 2 seconds.

This is the only upper bound in the section and it is deliberately loose. It exists to catch a delay that ignores the parameter in the other direction - a fixed multi-second sleep would otherwise satisfy every lower bound above. It is not a measurement of timer precision.

## 32 overlapping requests, 32 different delays

Issues 32 requests at once, each carrying a different delay between 100 ms and 499 ms, and verifies that every one of them comes back `200`, echoes **its own** value, and took at least its own delay.

This is the check a per-server or per-connection global cannot pass. Storing "the current delay" in one place answers every sequential check above correctly and falls apart as soon as two requests overlap, which is the only state this profile is ever benchmarked in.

The elapsed wall time for the batch is printed alongside the result. It is reported, not asserted: a thread-per-request server legitimately takes the sum of the delays here.
