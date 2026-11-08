---
title: Validation
seo_title: "JSON over HTTP/2 Cleartext Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the JSON over HTTP/2 cleartext benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `json-h2c` test. Port 8082 must already be answering h2c prior-knowledge before these checks begin.

## /json HTTP/2 cleartext

Sends `GET /json/1?m=1` to `http://localhost:8082` with `curl --http2-prior-knowledge`. The negotiated protocol must report **HTTP/2** - verifies the `/json` path isn't routed through an HTTP/1.1 fallback handler while `/baseline2` correctly speaks h2c.

## Content-Type

Response must include `Content-Type: application/json` (charset suffix permitted).

## Correctness across four (count, m) pairs

Sends four requests with a random `count` (1–50) and a random `m` (2–97), drawn fresh on every run so no response can be prepared in advance. For each response: the `count` field must equal the requested count, `items.length` must equal the count, every item must carry the full schema (`id`, `name`, `category`, `price`, `quantity`, `active` boolean, `tags` array, `rating` object with `score`+`count`, and `total`), the items must be the first `count` entries of `data/dataset.json` unchanged, and `total == price * quantity * m`. Partial payloads that omit fields are rejected.
