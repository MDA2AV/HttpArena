---
title: Implementation Guidelines
seo_title: "HTTP Pipelining Benchmark (16x): Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP pipelining benchmark."
---
{{< type-rules standard="Must use the framework standard request handling. No custom pipeline batching or read-ahead optimizations." tuned="May implement custom pipeline batching, read buffer optimizations, or framework-specific pipelining flags." engine="No specific rules. Ranked separately from frameworks." infrastructure="Configuration is free - worker counts, buffer sizes, event-loop and socket tuning are all allowed. Each request in a batch must produce its own response; coalescing the batch into one pre-built buffer, or answering from a cache keyed on the request line, is not allowed. This is the one profile scored for infrastructure and not for frameworks - for a proxy, pipelining behaviour is the thing being compared." >}}


16 HTTP requests are sent back-to-back on each connection before waiting for responses. Uses a lightweight `GET /pipeline` endpoint that returns a fixed `ok` response, isolating raw I/O throughput from application logic.

**This test is reference-only - it does not contribute to the composite score.** HTTP/1.1 pipelining is disabled in modern browsers and unsupported by mainstream proxies, so the profile is kept as a raw I/O and middleware-efficiency indicator (issue #1058). Results still appear on the board as a faded column.

**Connections:** 512, 4,096

## Expected request/response

```
GET /pipeline HTTP/1.1
```

```
HTTP/1.1 200 OK
Content-Type: text/plain

ok
```

## What it measures

- HTTP pipelining support and efficiency
- Frameworks that parse multiple requests from a single read buffer gain a major advantage
- Frameworks processing one request at a time per connection see minimal improvement over baseline
- Network batching, write coalescing, and syscall reduction

## Why a separate endpoint?

The `/pipeline` endpoint removes application-level variance (query parsing, body handling) so the benchmark measures pure I/O and protocol handling throughput. This isolates the framework ability to batch and process pipelined requests efficiently.
