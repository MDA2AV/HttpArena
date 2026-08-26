---
title: Implementation Guidelines
seo_title: "Async Delay Benchmark — Implementation Guide"
description: "Endpoint contract, response shape, and the anti-cheat constraints a framework must satisfy for the async delay benchmark."
---
{{< type-rules standard="Bind `/delay/{ms}` with the framework's own router and wait with the framework's own idiomatic mechanism. Blocking the request's thread for the duration is permitted - it is a legitimate implementation and the profile exists to price it - but you may not answer before the delay has elapsed, and the delay must be read from the path on every request." tuned="May use a custom timer wheel, a dedicated timer thread, coarser timer granularity, or batched expiry, so long as no response leaves before its own delay has elapsed." engine="Must derive the wait from the request path with a real timer. A fixed configured interval, a static delay directive, or anything that answers without reading `{ms}` is not an implementation of this profile." >}}


The Async Delay profile measures what a framework does with a request it cannot answer yet.

Every other HTTP/1.1 profile here is answered the moment it arrives; the only thing separating frameworks is how fast they can do that. Real services do not work that way. They call a database, a cache, another service, and while that call is outstanding the request is idle. A framework that suspends the request and keeps the thread carries thousands of those concurrently. A framework that blocks the thread carries as many as it has threads.

This profile isolates that difference and nothing else. There is no database, no network hop, no serialization, no I/O of any kind - just a timer, so the number that comes out is a property of the framework's concurrency model rather than of a driver someone else wrote.

**Connections:** 32,768 and 49,152

## How it works

1. Each request is `GET /delay/{ms}`, where `{ms}` is a whole number of milliseconds
2. The framework parses `{ms}` from the path
3. The framework waits that long
4. The framework responds `200` with the parsed number as the body and `Content-Type: text/plain`

The load generator holds every connection open for the whole run, so at 49,152 connections the server has 49,152 requests outstanding at all times, each with its own deadline.

## Expected response

```
GET /delay/37 HTTP/1.1
```

```
37
```

with `Content-Type: text/plain`.

The body is the parsed integer, in decimal, with no surrounding whitespace or JSON. `GET /delay/0` is a valid request that must answer immediately with `0` - zero is a delay of zero, not a missing parameter.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /delay/{ms}` |
| Delay | drawn per request, uniform over 10-30 ms |
| Connections | 32,768 and 49,152 |
| Pipeline | 1 |
| Requests per connection | unlimited (connections are held for the whole run) |
| Duration | 15s |
| Runs | 3 (best taken) |

The delay is rewritten by the load generator on every request from a `{RAND:10:30}` placeholder, so the value asked for is chosen after the container is already running and cannot be answered from anything prepared at startup.

## The throughput ceiling

A connection cannot have more than one request in flight, and each request occupies its connection for at least its delay. So the whole profile has an arithmetic ceiling:

```
max rps = connections / mean(delay)
```

With a mean delay of 20 ms that is roughly **1.64M rps at 32,768 connections** and **2.46M at 49,152**. Nothing can exceed it while honouring the delays, which makes the ceiling a free correctness check: a result above it is not a fast server, it is a server that did not wait.

The gap between a framework's number and that ceiling is what the profile actually reports. Reaching it means holding every connection's timer without the timers themselves becoming the bottleneck.

For a blocking implementation the ceiling is much lower, and it is set by the thread count rather than the connection count:

```
max rps = threads / mean(delay)
```

A 64-thread server at a 20 ms mean tops out near 3,200 rps no matter how many connections are offered.

## Implementation notes

- **Prefer a real async wait.** `await Task.Delay(ms)`, `tokio::time::sleep`, `asyncio.sleep`, `setTimeout`, `time.After`, a suspended coroutine - whatever your framework's own idiom is. These cost a timer entry and keep the worker free
- **Do not `Thread.sleep` on an event loop.** On a single-threaded or thread-per-core runtime this stalls every other connection that thread owns, not just this request. It is the one shape that will look worse here than a plain thread-per-request server
- **Per-request state.** The delay belongs to the request. A field on the server, the connection, or a shared handler instance is read back by whichever request finishes parsing last, and validation runs 32 overlapping requests with 32 different delays specifically to find that
- **Timer granularity.** The shortest delay asked for is 10 ms, comfortably above the resolution of every mainstream runtime on Linux. Rounding up a little is fine; the profile never asserts an upper bound on a single response
- **Do not create a thread per request.** At 49,152 concurrent requests that is 49,152 threads. Frameworks without an async model should block on whatever pool they already have and accept the result - see the ceiling above
- **No I/O.** Do not sleep by polling a socket, opening a file, or querying anything. The profile is a timer and nothing else

## Scoring

This profile is currently **reference-only**: it is measured, published and shown on the board, but it does not contribute to the composite score while its delay range and connection counts are still being tuned ([#1310](https://github.com/MDA2AV/HttpArena/issues/1310)).

When it is scored, it will count for framework entries (flagship, emerging, experimental) and for engines. Infrastructure entries are excluded - a reverse proxy has no application handler to wait in, so the thing being measured does not exist for that tier.
