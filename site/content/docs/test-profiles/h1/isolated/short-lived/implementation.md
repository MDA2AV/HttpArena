---
title: Implementation Guidelines
seo_title: "Short-lived Connection Benchmark — Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the short-lived connection benchmark."
---
{{< type-rules standard="Must use the framework default connection handling. No custom keep-alive tuning or connection pooling optimizations." tuned="May optimize connection recycling, TCP fast-open, and socket reuse settings." engine="No specific rules. Ranked separately from frameworks." infrastructure="Configuration is free - worker counts, buffer sizes, event-loop and socket tuning are all allowed. Every connection must complete a real accept and close - reuseport and accept-queue tuning are allowed, carrying connections across the 10-request window is not." >}}


Same workload as baseline, but each connection is closed and re-established after 10 requests. This forces frequent TCP handshakes.

**Connections:** 512, 4,096

## Expected request/response

Same as baseline - sum of query parameters:

```
GET /baseline11?a=13&b=42 HTTP/1.1
```

```
HTTP/1.1 200 OK
Content-Type: text/plain

55
```

## What it measures

- Socket creation and teardown overhead
- Connection accept rate
- Per-connection memory allocation/deallocation
- Any connection pooling or caching strategies

## Real-world relevance

Many clients (mobile, IoT, load balancers without keepalive) do not maintain long-lived connections. This profile captures how well a framework handles the constant churn of short-lived connections - a common pattern in production environments.
