---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `upload` test.

## Small body upload

Sends `POST /upload` with body `Hello, HttpArena!` (17 bytes) and `Content-Type: application/octet-stream`. Verifies the response body is `17` (the byte count of the uploaded data).

## Anti-cheat: random body upload

Generates a random 48-byte body (base64-encoded from 64 random bytes), sends `POST /upload` with that body, and verifies the response matches the exact byte count of the random payload. This detects hardcoded responses or implementations that return `Content-Length` instead of actually reading the body.

## Varying payload sizes

Sends `POST /upload` with four different payload sizes: **500 KB, 2 MB, 10 MB, and 20 MB** (random binary data). Verifies the returned byte count matches the exact payload size for each.
