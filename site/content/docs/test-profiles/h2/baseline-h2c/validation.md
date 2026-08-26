---
title: Validation
seo_title: "HTTP/2 Cleartext Baseline Benchmark (h2c): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/2 cleartext baseline benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `baseline-h2c` test. Port 8082 must be responding to a prior-knowledge h2 connection before checks begin.

## HTTP/2 cleartext (prior-knowledge)

Sends `GET /baseline2?a=1&b=1` to `http://localhost:8082` with `curl --http2-prior-knowledge`. The negotiated protocol (`%{http_version}`) must report **HTTP/2**. A server answering HTTP/1.1 here fails this check.

The listener may also serve HTTP/1.1 on the same port. Nothing in the benchmark reaches that path: `h2load -p h2c` sends the HTTP/2 connection preface as the first bytes of every connection and never issues an HTTP/1.1 request, so a dual-serving port is still measured as h2c.

## GET /baseline2 over h2c

Sends `GET /baseline2?a=13&b=42` with prior-knowledge h2c and verifies the response body is `55`.

## Anti-cheat: randomized query parameters

Generates random values for `a` and `b` (100–999), sends the request over h2c, and verifies the response matches the expected sum. Detects hardcoded responses.

## Content-Type

Response must include `Content-Type: text/plain` (charset suffix permitted).
