---
title: Implementation Guidelines
---
{{< type-rules standard="Must use the framework standard request handling. No custom pipeline batching or read-ahead optimizations." tuned="May implement custom pipeline batching, read buffer optimizations, or framework-specific pipelining flags." engine="No specific rules. Ranked separately from frameworks." >}}


16 HTTP requests are sent back-to-back on each connection before waiting for responses. Uses a lightweight `GET /pipeline` endpoint that returns a fixed `ok` response, isolating raw I/O throughput from application logic.

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
