---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard JSON serialization and the framework or engine's built-in response compression (middleware, filter, or equivalent). No pre-compressed caches, no bypassing the response pipeline." tuned="May use alternative JSON libraries, tuned compression libraries, or framework-specific optimizations as long as the output is valid gzip or brotli." engine="No specific rules." >}}

The JSON Compressed profile is the same workload as [JSON Processing](../json-processing/implementation/) with one difference: the client sends `Accept-Encoding: gzip, br` and the server must return a compressed response with a matching `Content-Encoding` header.

## How it works

1. Server reads `/data/dataset.json` at startup (same 50-item dataset as JSON Processing)
2. On each `GET /json/{count}?m={multiplier}` request, the server:
   - Takes the first `count` items from the dataset (1–50)
   - Computes `total = price × quantity × m` per item
   - Serializes to JSON
   - Compresses the response body with gzip or brotli
   - Returns `Content-Type: application/json` and `Content-Encoding: gzip` (or `br`)
3. When the client does **not** send `Accept-Encoding`, the server **must not** set `Content-Encoding` — compression is per-request, driven by the client header

The benchmark round-robins across counts 1, 5, 10, 15, 25, 40, and 50 paired with multipliers 3, 7, 2, 5, 4, 8, 6.

## What it measures

- Everything [JSON Processing](../json-processing/implementation/#what-it-measures) measures
- **Response compression throughput** — gzip or brotli encoding of the serialized body
- **Content negotiation** — honoring `Accept-Encoding` per request
- **Framework compression middleware overhead** — how cheaply the framework wires compression into the response pipeline

## Expected response

For `GET /json/5?m=3` with `Accept-Encoding: gzip, br`:

```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Encoding: gzip
```

Decompressed body:

```json
{
  "items": [
    {
      "id": 1,
      "name": "Alpha Widget",
      "category": "electronics",
      "price": 328,
      "quantity": 15,
      "active": true,
      "tags": ["fast", "new"],
      "rating": { "score": 48, "count": 127 },
      "total": 14760
    }
  ],
  "count": 5
}
```

`total` is `price * quantity * m` — integer arithmetic, no rounding. For `GET /json/5?m=1`, `total` equals `price * quantity`; the multiplier is never implicitly 1.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /json/{count}?m={multiplier}` |
| Counts × multipliers | (1,3), (5,7), (10,2), (15,5), (25,4), (40,8), (50,6) (round-robin) |
| Connections | 512, 4096, 16384 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Request headers | `Accept-Encoding: gzip, br` |
| Dataset | 50 items, mounted at `/data/dataset.json` |
