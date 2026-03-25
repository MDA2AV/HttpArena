---
title: Compression
---

The Compression profile measures the throughput cost of real-time gzip compression. Only frameworks with built-in compression support and a configurable compression level are eligible.

**Connections:** 4,096, 16,384

## How it works

1. At startup, the server loads `/data/dataset-large.json` — a 6,000-item dataset
2. Processes each item (computes a `total` field), serializes to JSON (~1 MB response)
3. On each `GET /compression` request with `Accept-Encoding: gzip`, the server compresses the response on the fly
4. Returns the gzip-compressed JSON

## What it measures

- **Gzip compression throughput** — CPU cost of compressing a 1 MB response per request
- **Compression implementation quality** — framework/server gzip performance differences
- **Throughput vs. bandwidth tradeoff** — fewer bytes on the wire but more CPU per request

## Eligibility

A framework must meet **both** requirements:

1. **Built-in compression** — the framework must have native gzip support. Custom gzip implementations or third-party compression libraries are not permitted.
2. **Configurable compression level** — the framework must allow setting gzip to its fastest level (level 1). Frameworks that hardcode the compression level and don't expose configuration are excluded, since compression level has a significant impact on both throughput and output size.

Frameworks excluded due to no built-in compression: hyper, Node.js, Express, Deno, Flask.

Frameworks excluded due to non-configurable compression level: actix, drogon, Spring Boot (Tomcat).

## Compression level

All participating frameworks use **gzip level 1** (fastest) unless noted otherwise. This ensures a fair comparison by isolating framework and I/O overhead from compression algorithm tuning.

**Exception:** Spring Boot (Jetty) uses gzip level 6 (default) as Spring Boot does not expose a compression level configuration. The bandwidth-adjusted scoring formula accounts for this — better compression (smaller responses) benefits the score, but the higher CPU cost per request reduces throughput.

## Expected response

```
GET /compression HTTP/1.1
Accept-Encoding: gzip
```

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Encoding: gzip

(gzip-compressed ~1 MB JSON)
```

The response JSON follows the same structure as the [JSON Processing](../json-processing) endpoint: `{"items": [...], "count": N}`. The `count` field must be dynamically computed from the number of items (e.g. `len(items)`, `items.length`, `items.size()`), not hardcoded to `6000`.

## Scoring

Raw requests per second alone is not a fair metric for compression benchmarks. A framework that compresses less aggressively produces larger responses, reducing CPU cost per request and inflating its RPS — but at the expense of bandwidth efficiency.

To account for this, the compression score adjusts RPS by the **bandwidth per request** (average compressed response size):

```
bw_per_req   = bandwidth / rps
penalty      = (min(bw_per_req) / bw_per_req)²
adjusted_rps = rps × penalty
score        = (adjusted_rps / max(adjusted_rps)) × 100
```

- `bw_per_req` — average bytes transferred per request (higher = worse compression)
- `min(bw_per_req)` — the smallest value across all frameworks (best compressor)
- `penalty` — squared ratio ≤ 1.0; frameworks with the best compression get no penalty, others are reduced quadratically
- The framework with the highest adjusted RPS scores **100**, others scale down

The squared penalty amplifies the cost of worse compression. A framework that compresses 30% less efficiently (30% larger responses) has its RPS multiplied by ~0.59 instead of ~0.77 with a linear penalty.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /compression` |
| Connections | 4,096, 16,384 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Gzip level | 1 (fastest) |
| Dataset | 6,000 items, mounted at `/data/dataset-large.json` |
| Uncompressed size | ~1 MB |
