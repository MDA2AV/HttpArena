---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `json-h2c` test. Port 8082 must already be answering h2c prior-knowledge before these checks begin (the `baseline-h2c` anti-cheat block covers the h1-rejection check — this block assumes it has passed).

## /json HTTP/2 cleartext

Sends `GET /json/1?m=1` to `http://localhost:8082` with `curl --http2-prior-knowledge`. The negotiated protocol must report **HTTP/2** — verifies the `/json` path isn't routed through an HTTP/1.1 fallback handler while `/baseline2` correctly speaks h2c.

## Content-Type

Response must include `Content-Type: application/json` (charset suffix permitted).

## Correctness across four (count, m) pairs

Sends four requests with `(count, m)` ∈ `{(12, 3), (22, 7), (31, 2), (50, 5)}` — deliberately distinct from the benchmark's seven rotation pairs so any caching-by-key strategy returns stale data. Each response's `count` field must equal the requested count, and `items.length` must equal the count.
