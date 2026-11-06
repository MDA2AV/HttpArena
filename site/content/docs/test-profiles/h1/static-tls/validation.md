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
- `GET /static/%7E%40file%20name.txt` - expects `Content-Type: text/plain`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

## File size verification (uncompressed)

Requests all 21 static files **without** `Accept-Encoding` and compares the response size against the actual file size on disk. All 21 files must match exactly. This ensures the server returns uncompressed content when no compression is requested.

`reset.css`, `layout.css`, `theme.css`, `components.css`, `utilities.css`, `analytics.js`, `helpers.js`, `app.js`, `vendor.js`, `router.js`, `header.html`, `footer.html`, `regular.woff2`, `bold.woff2`, `logo.svg`, `icon-sprite.svg`, `hero.webp`, `thumb1.webp`, `thumb2.webp`, `manifest.json`, `~@file name.txt` (requested as `%7E%40file%20name.txt`)

## Compression verification

Requests all 21 static files **with** `Accept-Encoding: br;q=1, gzip;q=0.8` and checks:

- If the server returns a `Content-Encoding` header (br or gzip), the decompressed response size must match the original file size on disk
- If the server does not compress a file, it is counted as skipped (not a failure - compression is optional)

**PASS** if all compressed files decompress to the correct size. **SKIP** if the server does not compress any files. **FAIL** if any compressed file decompresses to the wrong size.

## 404 for nonexistent file

Sends `GET /static/nonexistent.txt` and verifies the server returns **HTTP 404**.

## Percent-encoded path

Requests `~@file name.txt` without `Accept-Encoding` under four spellings and requires **HTTP 200** with exactly the bytes on disk for each:

| Spelling | What it catches |
|----------|-----------------|
| `/static/%7E%40file%20name.txt` | the benchmark's own request: no decoding at all |
| `/static/%7e%40file%20name.txt` | a decoder that only knows upper-case hex |
| `/static/~@file%20name.txt` | a route or lookup keyed on the benchmark's literal spelling |
| a spelling drawn per run, e.g. `/static/~%40f%69l%65%20na%6De.txt` | anything prepared for a fixed set of spellings |

The per-run spelling always encodes the space, leaves the dot alone, and encodes every other character or not at random, in either hex case. Every spelling goes on the wire exactly as written. The PASS line names the one that was drawn, and a FAIL line names the one that failed.

Then it sends `GET /static/%7E%40file%2520name.txt`. Decoded once, that names a file called `~@file%20name.txt`, which does not exist, so the answer must be **HTTP 404** (400 is accepted too). A 200 means the server decoded the path twice, which is the classic path-traversal bug.

```
PASS [static-tls percent-decoded path] (4 spellings of '~@file name.txt' served, incl. /static/~%40f%69l%65%20na%6De.txt)
PASS [static-tls percent-decoded path, decoded once] (GET /static/%7E%40file%2520name.txt -> HTTP 404)
```

The file is also part of the size and compression checks above. See [Percent-encoded paths](/docs/test-profiles/h1/static-tls/implementation/#percent-encoded-paths) for what the server has to do.

## TLS checks

This profile's TLS listener on port 8081 also goes through the shared TLS checks. The certificate must be the one the harness mounted, the connection must negotiate TLS 1.3 with an AEAD cipher, ALPN must not name a protocol the client did not offer, and the server must accept no obsolete protocol or weak cipher. They are documented once, under [json-tls validation](../json-tls/validation/#tls-checks).
