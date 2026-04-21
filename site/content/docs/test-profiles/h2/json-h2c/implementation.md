---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard JSON serialization and standard HTTP/2 cleartext configuration. No pre-serialized caches, no custom serializers, no bypassing the framework response pipeline." tuned="May use alternative JSON libraries (simd-json, sonic-json), tune HTTP/2 stream and window parameters, and apply framework-specific optimizations. The JSON body must still be serialized per request from live data — pre-computed / pre-serialized response caches or response-lookup tables are not allowed on either type; they short-circuit the serialization workload the profile exists to measure." engine="No specific rules. Ranked separately from frameworks." >}}

Same [JSON Processing](../../../h1/isolated/json-processing/) workload (dataset slice + per-item derived field + JSON serialization) served over HTTP/2 cleartext. Exercises the JSON pipeline under multiplexed h2 streams without the TLS CPU tax the `baseline-h2` profile carries.

**Port:** 8082
**Connections:** 4,096
**Concurrent streams per connection:** 32
**Negotiation:** prior-knowledge (`h2load -p h2c`)

## Workload

The load generator rotates through the same seven `(count, m)` pairs as the H/1 JSON profile:

`(1, 3)`, `(5, 7)`, `(10, 2)`, `(15, 5)`, `(25, 4)`, `(40, 8)`, `(50, 6)`

`count` selects a slice of the shared `/data/dataset.json` (50 items); `m` is the per-request multiplier that feeds into each item's `total = price × quantity × m`. Different multipliers per request ensure naive caching by path returns wrong values.

## What it measures

- JSON serialization throughput over h2c (no TLS in the way)
- h2 multiplexing efficiency when response bodies vary in size (1 → 50 items)
- How cleanly the framework refuses HTTP/1.1 on the h2c-only port (validated per `baseline-h2c`'s anti-cheat)

## Expected request/response

```
GET /json/5?m=3 HTTP/2
```

```
HTTP/2 200 OK
Content-Type: application/json

{"count":5,"items":[…5 items, each with total = price*quantity*3…]}
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /json/{count}?m={multiplier}` |
| Connections | 4,096 |
| Streams per connection | 32 (`-m 32`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load with `-p h2c` and URI rotation (`-i json-h2c-uris.txt`) |
