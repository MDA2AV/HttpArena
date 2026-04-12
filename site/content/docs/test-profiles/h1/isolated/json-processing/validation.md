---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `json` test.

## Response structure and computed totals

Sends `GET /json/{count}` for counts **12, 22, 31, and 50** (different from the benchmark counts to prevent hardcoded responses). For each request, verifies:

- The response contains exactly **count** items
- Every item has a `total` field
- Each `total` is correctly computed as `price * quantity`, rounded to 2 decimal places (tolerance: 0.01)

## Content-Type header

Sends `GET /json/50` and verifies the `Content-Type` response header is `application/json`.
