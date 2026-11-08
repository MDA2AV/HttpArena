---
title: Validation
seo_title: "Async Database Benchmark (Postgres): Validation Checks"
description: "The correctness checks validate.sh runs against the async Postgres benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `async-db` test. A Postgres sidecar container is started automatically before these checks run.

## Response structure with varying limits

Sends four `GET /async-db?min=M&max=N&limit=L` requests with values drawn at random on every run: `min` between 1 and 120, `max` 20 to 300 above `min`, and `limit` between 1 and 50. Because they are random, a hardcoded response cannot pass. For each request, verifies:

- **Item count** equals the requested limit
- Every item has a nested `rating` object with a `score` field
- Every item has a `tags` field that is an array
- Every item has an `active` field that is a boolean (`true`/`false`)

## Content-Type header

Sends `GET /async-db?min=10&max=50&limit=50` and verifies the `Content-Type` response header is `application/json`.

## Anti-cheat: empty range

Sends `GET /async-db?min=9999&max=9999&limit=50` (a price range with no matching items) and verifies the response has `count` equal to `0`. This detects hardcoded responses or implementations that ignore the query parameters.
