---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard JSON serialization. No pre-serialized caches, no custom serializers, no bypassing the framework response pipeline." tuned="May use alternative JSON libraries (simd-json, sonic-json), pre-computed responses, or framework-specific optimizations." engine="No specific rules." >}}


The JSON Processing profile measures how efficiently a framework handles a typical real-world API workload: loading data, computing derived fields, and serializing a JSON response.

## How it works

1. At startup, the server reads `/data/dataset.json` — a file containing 50 items with mixed types (strings, numbers, booleans, arrays, nested objects)
2. On each `GET /json/{count}` request, the server:
   - Takes the first `count` items from the dataset (1–50)
   - Computes a `total` field (`price × quantity`) for each item
   - Builds the response object
   - Serializes everything as JSON
3. Returns `Content-Type: application/json`

The benchmark round-robins across counts 1, 5, 10, 15, 25, 40, and 50, testing serialization performance across varying response sizes.

## What it measures

- **Object allocation** - 1–50 new objects built per request, varying across requests
- **JSON serialization** - converting native data structures to JSON text
- **Mixed-type handling** - strings, numbers, booleans, arrays, nested objects
- **Route parameter parsing** - extracting the count from the URL path
- **Framework response overhead** - buffering, headers, content-type handling

## Dataset format

Each item in `dataset.json`:

```json
{
  "id": 1,
  "name": "Alpha Widget",
  "category": "electronics",
  "price": 328,
  "quantity": 15,
  "active": true,
  "tags": ["fast", "new"],
  "rating": {
    "score": 48,
    "count": 127
  }
}
```

## Expected response

For `GET /json/5?m=3`:

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

The `count` field must match the number of items returned and the route parameter. The `total` field is computed as `price * quantity * m` (all integers — no rounding needed). The server must return the first `count` items from the dataset.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /json/{count}` |
| Counts | 1, 5, 10, 15, 25, 40, 50 (round-robin) |
| Connections | 4,096 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Dataset | 50 items, mounted at `/data/dataset.json` |
