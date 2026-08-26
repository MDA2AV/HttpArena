---
title: Validation
seo_title: "HTTP/2 Baseline Benchmark (TLS): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/2 TLS baseline benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `baseline-h2` test. The HTTPS port (8443) must be responding before checks begin.

## HTTP/2 protocol negotiation

Sends a request to `https://localhost:8443/baseline2?a=1&b=1` using `--http2` and checks the negotiated protocol version. The server must respond with **HTTP/2** (not HTTP/1.1 fallback).

## GET /baseline2 over HTTP/2

Sends `GET /baseline2?a=13&b=42` over HTTPS with HTTP/2 and verifies the response body is `55`.

## Anti-cheat: randomized query parameters

Generates random values for `a` and `b` (100-999), sends `GET /baseline2?a={a}&b={b}` over HTTP/2, and verifies the response matches the expected sum. This detects hardcoded responses.

## TLS checks

This profile's TLS listener on port 8443 also goes through the shared TLS checks. The certificate must be the one the harness mounted, the connection must negotiate TLS 1.3 with an AEAD cipher, ALPN must not name a protocol the client did not offer, and the server must accept no obsolete protocol or weak cipher. They are documented once, under [json-tls validation](../../h1/isolated/json-tls/validation/#tls-checks).
