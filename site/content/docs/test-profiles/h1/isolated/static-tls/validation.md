---
title: Validation
seo_title: "Static File Serving Benchmark (HTTP/1.1 + TLS): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/1.1 + TLS static file benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `static-tls` test. They mirror the [`static` checks](../../static/validation/), performed over HTTPS on port 8081.

## ALPN negotiates HTTP/1.1

```
curl -sk --http1.1 https://localhost:8081/static/reset.css
```

The response must report `http_version = 1.1`. A framework that advertises only `h2` on port 8081, or that refuses HTTP/1.1 clients, fails this check.

## Content-Type headers

Verifies correct `Content-Type` headers for representative file types:

- `GET /static/reset.css` - expects `Content-Type: text/css`
- `GET /static/app.js` - expects `Content-Type: application/javascript`
- `GET /static/manifest.json` - expects `Content-Type: application/json`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

## File size verification (uncompressed)

Requests all 20 static files **without** `Accept-Encoding` and compares the response size against the actual file size on disk. All 20 files must match exactly. This ensures the server returns uncompressed content when no compression is requested.

`reset.css`, `layout.css`, `theme.css`, `components.css`, `utilities.css`, `analytics.js`, `helpers.js`, `app.js`, `vendor.js`, `router.js`, `header.html`, `footer.html`, `regular.woff2`, `bold.woff2`, `logo.svg`, `icon-sprite.svg`, `hero.webp`, `thumb1.webp`, `thumb2.webp`, `manifest.json`

## Compression verification

Requests all 20 static files **with** `Accept-Encoding: br;q=1, gzip;q=0.8` and checks:

- If the server returns a `Content-Encoding` header (br or gzip), the decompressed response size must match the original file size on disk
- If the server does not compress a file, it is counted as skipped (not a failure - compression is optional)

**PASS** if all compressed files decompress to the correct size. **SKIP** if the server does not compress any files. **FAIL** if any compressed file decompresses to the wrong size.

## 404 for nonexistent file

Sends `GET /static/nonexistent.txt` and verifies the server returns **HTTP 404**.

## TLS checks

This profile's TLS listener on port 8081 also goes through the shared TLS checks. The certificate must be the one the harness mounted, the connection must negotiate TLS 1.3 with an AEAD cipher, ALPN must not name a protocol the client did not offer, and the server must accept no obsolete protocol or weak cipher. They are documented once, under [json-tls validation](../json-tls/validation/#tls-checks).
