---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `json` test.

## Response structure and computed totals

Sends `GET /json/{count}` for counts **12, 22, 31, and 50** (different from the benchmark counts to prevent hardcoded responses). For each request, verifies:

- The response contains exactly **count** items
- Every item contains the full schema - `id`, `name`, `category`, `price`, `quantity`, `active`, `tags` (array), `rating` (object with `score` and `count`), and `total`. Partial payloads that omit fields are rejected.
- Each `total` is correctly computed as `price * quantity * m`

## Content-Type header

Sends `GET /json/50` and verifies the `Content-Type` response header is `application/json`.
