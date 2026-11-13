---
title: Validation
seo_title: "Compressed JSON Benchmark (gzip and Brotli): Validation Checks"
description: "The correctness checks validate.sh runs against the compressed JSON benchmark before a framework's results are accepted."
---

The validation script (`scripts/validate.sh`) runs these checks for the `json-comp` test profile. All must pass for a framework to be considered valid for this benchmark.

Counts and multipliers are drawn at random on every run, after the container is up, so no response can be prepared in advance.

## Checks

### Response body matches the dataset

Four uncompressed requests `GET /json/{count}?m={m}` are sent with random `count` (1–50) and `m` (2–97). For each response the validator checks:

1. `count` field equals the route count
2. Every item in `items` contains the full schema - `id`, `name`, `category`, `price`, `quantity`, `active` (boolean), `tags` (array), `rating` (object with `score` and `count`), and `total`
3. The items are the first `count` entries of `data/dataset.json`, unchanged - `id`, `name`, `category`, `price`, `quantity`, `active` and `tags` are compared field by field
4. `total == price * quantity * m` for every item (integer, exact)

A made-up item with a self-consistent `total` fails here, because every field is compared against the dataset rather than only against the response's own arithmetic.

### Content-Type is application/json

```
GET /json/50?m=1
```

The response must carry `Content-Type: application/json`.

### Content-Encoding is set when Accept-Encoding is sent

```
GET /json/50?m=1
Accept-Encoding: gzip, br
```

The response must include `Content-Encoding: gzip` or `Content-Encoding: br`. Any other value (including absent) is a failure.

### Compressed responses are correct

Three requests are sent with `Accept-Encoding: gzip, br`, random `count` (5–50) and random `m` (2–89). Each response is decompressed and must have the right `count`, the full item schema, and `total == price * quantity * m` for every item. This confirms the server honors the `m` parameter and applies it per item, also on the compressed path.

### No Content-Encoding when Accept-Encoding is absent

```
GET /json/50?m=1
```

Without `Accept-Encoding`, the response **must not** include a `Content-Encoding` header. Compression is driven per request by the client - servers that unconditionally compress fail this check.

## Running locally

```bash
./scripts/validate.sh <framework>
```

This runs the checks for every profile listed in the framework's `meta.json`.
