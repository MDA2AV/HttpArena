---
title: JSON Processing
---

The JSON Processing profile measures how efficiently a framework handles a typical real-world API workload: loading data, computing derived fields, and serializing a JSON response.

## How it works

1. At startup, the server reads `/data/dataset.json` — a file containing 50 items with mixed types (strings, numbers, booleans, arrays, nested objects)
2. On each `GET /json` request, the server:
   - Iterates all 50 items
   - Computes a `total` field (`price × quantity`) for each item
   - Builds the response object
   - Serializes everything as JSON (~10 KB response)
3. Returns `Content-Type: application/json`

## What it measures

- **Object allocation** — 50 new objects built per request
- **JSON serialization** — converting native data structures to JSON text
- **Mixed-type handling** — strings, numbers, booleans, arrays, nested objects
- **Framework response overhead** — buffering, headers, content-type handling

## Dataset format

Each item in `dataset.json`:

```json
{
  "id": 1,
  "name": "Alpha Widget",
  "category": "electronics",
  "price": 29.99,
  "quantity": 5,
  "active": true,
  "tags": ["fast", "new"],
  "rating": {
    "score": 4.2,
    "count": 127
  }
}
```

## Expected response

```json
{
  "items": [
    {
      "id": 1,
      "name": "Alpha Widget",
      "category": "electronics",
      "price": 29.99,
      "quantity": 5,
      "active": true,
      "tags": ["fast", "new"],
      "rating": { "score": 4.2, "count": 127 },
      "total": 149.95
    }
  ],
  "count": 50
}
```

The `count` field must be dynamically computed from the number of items (e.g. `len(items)`, `items.length`, `items.size()`), not hardcoded to `50`.

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /json` |
| Connections | 4,096, 16,384, 32,768 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Dataset | 50 items, mounted at `/data/dataset.json` |
