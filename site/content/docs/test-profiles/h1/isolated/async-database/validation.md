---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `async-db` test. A Postgres sidecar container is started automatically before these checks run.

## Response structure with varying limits

Sends `GET /async-db?min=M&max=N&limit=L` with varying price ranges and limits (different from the benchmark values to prevent hardcoded responses). Tested combinations: `min=5&max=80&limit=7`, `min=20&max=150&limit=18`, `min=100&max=400&limit=33`, `min=10&max=50&limit=50`. For each request, verifies:

- **Item count** equals the requested limit
- Every item has a nested `rating` object with a `score` field
- Every item has a `tags` field that is an array
- Every item has an `active` field that is a boolean (`true`/`false`)

## Content-Type header

Sends `GET /async-db?min=10&max=50&limit=50` and verifies the `Content-Type` response header is `application/json`.

## Anti-cheat: empty range

Sends `GET /async-db?min=9999&max=9999&limit=50` (a price range with no matching items) and verifies the response has `count` equal to `0`. This detects hardcoded responses or implementations that ignore the query parameters.
