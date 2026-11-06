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
- `GET /static/%7E%40file%20name.txt` - expects `Content-Type: text/plain`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

## Response size

Requests `GET /static/reset.css` over HTTP/2 and verifies the response size is greater than 0 bytes. This confirms the server is actually serving file content, not empty responses.

## 404 for nonexistent file

Sends `GET /static/nonexistent.txt` over HTTP/2 and verifies the server returns **HTTP 404**.

## Percent-encoded path

The same check as [over HTTP/1.1](/docs/test-profiles/h1/static-tls/validation/#percent-encoded-path), sent over HTTP/2: `~@file name.txt` is requested under four spellings of its name - the benchmark's `%7E%40file%20name.txt`, the same in lower-case hex, `~@file%20name.txt`, and one drawn per run - and each must come back **HTTP 200** with exactly the bytes on disk. `GET /static/%7E%40file%2520name.txt` must then answer **HTTP 404** (or 400): a 200 means the path was decoded twice.

```
PASS [static-h2 percent-decoded path] (4 spellings of '~@file name.txt' served, incl. /static/~%40f%69l%65%20na%6De.txt)
PASS [static-h2 percent-decoded path, decoded once] (GET /static/%7E%40file%2520name.txt -> HTTP 404)
```

## TLS checks

This profile's TLS listener on port 8443 also goes through the shared TLS checks. The certificate must be the one the harness mounted, the connection must negotiate TLS 1.3 with an AEAD cipher, ALPN must not name a protocol the client did not offer, and the server must accept no obsolete protocol or weak cipher. They are documented once, under [json-tls validation](../../h1/json-tls/validation/#tls-checks).
