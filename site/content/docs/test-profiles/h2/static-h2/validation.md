---
title: Validation
seo_title: "Static File Serving Benchmark (HTTP/2): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/2 static file benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `static-h2` test. The HTTPS port (8443) must be responding before checks begin.

## Content-Type headers

Verifies correct `Content-Type` headers for representative file types over HTTPS with HTTP/2:

- `GET /static/reset.css` - expects `Content-Type: text/css`
- `GET /static/app.js` - expects `Content-Type: application/javascript`
- `GET /static/manifest.json` - expects `Content-Type: application/json`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

## Response size

Requests `GET /static/reset.css` over HTTP/2 and verifies the response size is greater than 0 bytes. This confirms the server is actually serving file content, not empty responses.

## 404 for nonexistent file

Sends `GET /static/nonexistent.txt` over HTTP/2 and verifies the server returns **HTTP 404**.

## TLS checks

This profile's TLS listener on port 8443 also goes through the shared TLS checks. The certificate must be the one the harness mounted, the connection must negotiate TLS 1.3 with an AEAD cipher, ALPN must not name a protocol the client did not offer, and the server must accept no obsolete protocol or weak cipher. They are documented once, under [json-tls validation](../../h1/isolated/json-tls/validation/#tls-checks).
