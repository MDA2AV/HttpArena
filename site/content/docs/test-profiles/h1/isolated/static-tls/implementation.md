---
title: Implementation Guidelines
seo_title: "Static File Serving Benchmark (HTTP/1.1 + TLS) — Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/1.1 + TLS static file benchmark."
---
{{< type-rules standard="Must load files from disk on every request. No in-memory caching, no memory-mapped files, no pre-loaded file buffers. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving pre-compressed `.br`/`.gz` variants from disk **is allowed**, but only through a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`). No custom file-suffix lookup logic. TLS must come from a standard stack (OpenSSL, BoringSSL, rustls, SChannel, JDK JSSE, etc.) - no TLS session-ticket shortcuts that skip real handshakes." tuned="May cache files in memory at startup, use memory-mapped files, pre-rendered response headers, or any caching strategy. May serve pre-compressed files (.gz, .br) from disk via any mechanism. Free to use any compression approach and tuned TLS providers." engine="No specific rules." infrastructure="Configuration is free, including sendfile, open_file_cache, mmap and in-memory caching - serving files fast from a tuned cache is the job. Pre-compressed .br/.gz variants may be served through the server's own mechanism (nginx gzip_static / brotli_static, Caddy precompressed). Bodies must come from the mounted static directory; a handler that synthesizes them is not serving files. TLS must come from a standard stack (OpenSSL, BoringSSL, rustls, quictls) and every connection must complete a real handshake." >}}

The Static Files over TLS profile is the [Static Files](../static/implementation/) workload transported over HTTP/1.1 + TLS on a dedicated port. It measures how much of a framework's plaintext static-serving throughput survives encryption.

**Connections:** 1,024, 4,096, 6,800

## How it works

1. The framework serves the same 20 files from `/data/static/` as the plain `static` profile
2. The framework listens on **port 8081** with HTTPS, serving HTTP/1.1 only (ALPN advertises `http/1.1`)
3. The load generator ([wrk](https://github.com/wg/wrk)) requests the 20 files in a round-robin pattern using the same Lua rotation script as `static` (`requests/static-rotate.lua`), over `https://`
4. All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`

- **CSS** (5 files, 8–200 KB): `reset.css`, `layout.css`, `theme.css`, `components.css`, `utilities.css`
- **JavaScript** (5 files, 12–300 KB): `analytics.js`, `helpers.js`, `app.js`, `vendor.js`, `router.js`
- **HTML** (2 files, 55–120 KB): `header.html`, `footer.html`
- **Fonts** (2 files, 18–22 KB): `regular.woff2`, `bold.woff2`
- **SVG** (2 files, 15–70 KB): `logo.svg`, `icon-sprite.svg`
- **Images** (3 files, 6–45 KB): `hero.webp`, `thumb1.webp`, `thumb2.webp`
- **JSON** (1 file, 3 KB): `manifest.json`

Total payload: ~842 KB across 20 files (~743 KB compressible text + ~99 KB binary). Brotli-compressed total: ~219 KB.

Pre-compressed versions of all text files (`.gz` at level 9, `.br` at level 11) are available in the `data/static/` directory alongside the originals.

## Compression

Identical to the plain [`static` profile](../static/implementation/#compression): compression is **optional**, must come from standard middleware / documented pre-compressed-file APIs on **production** entries, and is unrestricted on **tuned** entries.

## Port, ALPN, and certificates

- **Port**: 8081 (distinct from 8080 plaintext and 8443 which is dedicated to HTTP/2 / HTTP/3 profiles), shared with the `json-tls` profile
- **ALPN**: advertise `http/1.1` only. HTTP/1.1-only clients (wrk) negotiate correctly and never upgrade to h2.
- **Certificates**: the same PEM files used by `json-tls` / `baseline-h2` / `static-h2`, mounted at `/certs/server.crt` and `/certs/server.key`. Frameworks typically read them via environment variables (`TLS_CERT`, `TLS_KEY`) or a hardcoded path, same pattern as the other TLS tests.

## What it measures

- Everything [Static Files](../static/implementation/#what-it-measures) measures
- **TLS handshake cost amortized over keep-alive** - connections are long-lived at 1,024–6,800 concurrent
- **Record framing overhead on large payloads** - multi-hundred-KB responses span many TLS records, unlike the small JSON bodies of `json-tls`
- **Symmetric cipher throughput** - AES-GCM / ChaCha20-Poly1305 on the hot path, dominated by bulk encryption of file bodies

## Expected request/response

```
GET /static/reset.css HTTP/1.1
Host: localhost:8081
Accept-Encoding: br;q=1, gzip;q=0.8
```

```
HTTP/1.1 200 OK
Content-Type: text/css
Content-Encoding: br

(compressed file contents)
```

Or without compression:

```
HTTP/1.1 200 OK
Content-Type: text/css

(file contents)
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | 20 URIs under `/static/*` |
| Transport | HTTP/1.1 over TLS |
| Port | 8081 |
| ALPN | `http/1.1` |
| Connections | 1,024, 4,096, 6,800 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | wrk + `requests/static-rotate.lua` |
| Certificates | mounted at `/certs/server.crt` + `/certs/server.key` |
