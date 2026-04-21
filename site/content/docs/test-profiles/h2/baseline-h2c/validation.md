---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `baseline-h2c` test. Port 8082 must be responding to a prior-knowledge h2 connection before checks begin.

## HTTP/2 cleartext (prior-knowledge)

Sends `GET /baseline2?a=1&b=1` to `http://localhost:8082` with `curl --http2-prior-knowledge`. The negotiated protocol (`%{http_version}`) must report **HTTP/2**. A server answering HTTP/1.1 here fails this check.

## Anti-cheat: h2c-only listener

Sends the same request with `curl --http1.1`. The server must **not** respond with an HTTP/1.1 200. If it does, the port is dual-serving h1 and h2c, which means the benchmark could silently measure HTTP/1.1 throughput instead of h2c. The check accepts any non-200 response (connection reset, GOAWAY, 400, etc.).

## GET /baseline2 over h2c

Sends `GET /baseline2?a=13&b=42` with prior-knowledge h2c and verifies the response body is `55`.

## Anti-cheat: randomized query parameters

Generates random values for `a` and `b` (100–999), sends the request over h2c, and verifies the response matches the expected sum. Detects hardcoded responses.

## Content-Type

Response must include `Content-Type: text/plain` (charset suffix permitted).
