---
title: Validation
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

## Static freshness (no pre-caching)

The same anti-pre-cache probe as the [HTTP/1.1 static validation](../../h1/isolated/static/validation) also runs over HTTP/2 on port 8443: it rewrites `reset.css` (and its `.gz`/`.br` siblings) on disk mid-run and polls each `Accept-Encoding` until the response reflects the change or the `STATIC_FRESHNESS_GRACE` window (default **30s**) elapses. `engine` and `infrastructure` types are **exempt** (skipped).

It runs here **only for entries subscribed to `static-h2` but not `static`** — when a framework also subscribes to the HTTP/1.1 `static` test, that test's freshness check already covers it, so the HTTP/2 probe is not repeated.

**PASS** if every served encoding reflects the change within the window. **FAIL** if any stays stale after it.
