---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard JSON serialization and the framework or engine's built-in response compression (middleware, filter, or equivalent). No pre-compressed caches, no bypassing the response pipeline." tuned="May use alternative JSON libraries, tuned compression libraries, and framework-specific optimizations as long as the output is valid gzip or brotli. The JSON body must still be serialized and compressed per request — pre-computed / pre-serialized / pre-compressed response caches are not allowed on either type; they defeat the serialization and compression workload the profile exists to measure." engine="No specific rules." >}}

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

## Scoring

Unlike most profiles where rank follows raw requests per second, **JSON Compressed is scored by a compression-weighted formula** so a framework that ships smaller response bodies wins over one that only serves more requests. This is the only profile in the suite that explicitly rewards compression ratio.

### The formula

For each framework, the server's actual bytes-per-response is computed from the benchmark output:

```
myBpr = observed_bandwidth / observed_rps
```

The framework with the **smallest** `myBpr` across the field sets the reference — that's the compression winner. Every framework's effective rps is then scaled by the squared ratio of reference to actual:

```
effectiveRps = rps × (minBpr / myBpr)²
```

The quadratic exponent is deliberate: **doubling the response size quarters the score**. A framework that serves twice the rps but ships 1.4× the bytes roughly breaks even; one that ships 2× the bytes pays 4× in score and needs to match 4× the rps just to stay level. The BW/req column on the leaderboard shows each framework's `myBpr` so you can see exactly what compression ratio the server picked (gzip at its chosen level, brotli, deflate — whatever `Accept-Encoding: gzip, br` returned).

### Per-conn-count table (per-profile leaderboard)

On the JSON Compressed tab of the main leaderboard, the Score column is computed **independently per connection count**. Each conn panel (512, 4096, 16384) runs its own `minBpr` normalization so the top framework in that panel scores 100. The **Best** panel picks each framework's highest score across the three conn counts.

### Composite score column

On the [composite leaderboard](/leaderboards/composite/), the JSON Compressed column follows a different aggregation path:

1. Average `rps` and `bandwidth` across the 3 conn counts (arithmetic mean, equal weight).
2. Compute `myBpr = avgBw / avgRps` from those averages.
3. Apply the same `effectiveRps = avgRps × (minBpr / myBpr)²` formula.
4. Normalize to 0–100.

The resulting per-profile score feeds into the composite like every other profile — averaged across all scored profiles for that framework's type.

### Consequences

- **A framework that picks brotli can dominate even at lower rps**, provided the smaller bytes-per-response wins back more score than the rps gap costs. This reflects real-world bandwidth-constrained serving.
- **Gzip-only frameworks are competitive when their compression level is aggressive enough** to keep `myBpr` near the brotli leader. The formula rewards ratio, not the specific encoding chosen.
- **Pre-computed compressed payloads are out of the question for `production` type** — the type rules require the response pipeline to actually compress per-request. See [type rules](/docs/add-framework/meta-json/#type-rules).
- **The best-conn-count panel on the profile tab can rank differently from the composite column**, because one picks the highest-scoring conn count and the other averages. Both are intentional: the profile tab answers "which framework wins at its best setting?"; the composite answers "which framework is most consistent across loads?".
