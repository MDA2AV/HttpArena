---
title: Implementation Guidelines
seo_title: "Static File Serving Benchmark (HTTP/1.1 + TLS): Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/1.1 + TLS static file benchmark."
---
{{< type-rules standard="File contents may be served from memory, but the cache must be the framework's own - a documented static file handler with whatever caching it comes with. A cache assembled in the entry does not count: no reading the directory into a map at startup, no pre-loaded buffers, no mapping the files by hand. The cache must also follow the disk: replace a file and the next response must carry the new bytes. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving the pre-compressed `.br`/`.gz` variants that sit on disk next to the originals **is allowed**, by a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`, Hono `serveStatic({ precompressed: true })`) where the framework has one, and otherwise by selecting the variant in the entry off `Accept-Encoding`. Those bytes already exist, so choosing one is a file read rather than compression - which is why this is allowed while compressing by hand is not. The response must carry the original file's `Content-Type`, the matching `Content-Encoding`, and must still follow the disk. TLS must come from a standard stack (OpenSSL, BoringSSL, rustls, SChannel, JDK JSSE, etc.) - no TLS session-ticket shortcuts that skip real handshakes." tuned="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. Pre-rendered response headers stay allowed, as does serving pre-compressed .gz/.br variants from disk via any mechanism, with any compression approach and tuned TLS providers." engine="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. No other restrictions." infrastructure="Configuration is free, including sendfile, open_file_cache, mmap and in-memory caching - serving files fast from a tuned cache is the job. Pre-compressed .br/.gz variants may be served through the server's own mechanism (nginx gzip_static / brotli_static, Caddy precompressed). Bodies must come from the mounted static directory; a handler that synthesizes them is not serving files. TLS must come from a standard stack (OpenSSL, BoringSSL, rustls, quictls) and every connection must complete a real handshake." >}}

The Static Files over TLS profile is the [Static Files](../static/implementation/) workload transported over HTTP/1.1 + TLS on a dedicated port. It measures how much of a framework's plaintext static-serving throughput survives encryption.

**Connections:** 1,024

## How it works

1. The framework serves the same 21 files from `/data/static/` as the plain `static` profile
2. The framework listens on **port 8081** with HTTPS, serving HTTP/1.1 only (ALPN advertises `http/1.1`)
3. The load generator ([wrk](https://github.com/wg/wrk)) requests the 21 files in a round-robin pattern using the same Lua rotation script as `static` (`requests/static-rotate.lua`), over `https://`
4. All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`

- **CSS** (5 files, 8–200 KB): `reset.css`, `layout.css`, `theme.css`, `components.css`, `utilities.css`
- **JavaScript** (5 files, 12–300 KB): `analytics.js`, `helpers.js`, `app.js`, `vendor.js`, `router.js`
- **HTML** (2 files, 55–120 KB): `header.html`, `footer.html`
- **Fonts** (2 files, 18–22 KB): `regular.woff2`, `bold.woff2`
- **SVG** (2 files, 15–70 KB): `logo.svg`, `icon-sprite.svg`
- **Images** (3 files, 6–45 KB): `hero.webp`, `thumb1.webp`, `thumb2.webp`
- **JSON** (1 file, 3 KB): `manifest.json`
- **Text** (1 file, 16 KB): `~@file name.txt`, requested as `/static/%7E%40file%20name.txt` - see [Percent-encoded paths](#percent-encoded-paths)

Total payload: ~1258 KB across 21 files (~1159 KB compressible text + ~99 KB binary). Brotli-compressed total: ~223 KB for the text; ~322 KB across all 21 files, since the five binary ones ship no pre-compressed twin.

Pre-compressed versions of all text files (`.gz` at level 9, `.br` at level 11) are available in the `data/static/` directory alongside the originals.

## Percent-encoded paths

One file in the set, `~@file name.txt`, has a name that cannot be sent in a URI as it is: the space has to be percent-encoded. The load generator sends all three special characters encoded, so the request is

```
GET /static/%7E%40file%20name.txt HTTP/1.1
```

and the server only finds the file if it percent-decodes the path ([RFC 3986, section 2.1](https://www.rfc-editor.org/rfc/rfc3986#section-2.1)) before looking it up. It is one request in 21 (~5%), so the cost of decoding shows up in the result without the profile becoming about it.

- Decode exactly once. `%2520` is a literal `%20` in the file name, not a space.
- Hex digits are case-insensitive: `%7e` and `%7E` are the same character.
- Any character may arrive encoded, including ones that do not need it (`%66` is `f`), and the same name may arrive with some characters encoded and others not.
- The response is `Content-Type: text/plain` (a `; charset=...` parameter is fine). Like the other text files, it has `.br` and `.gz` twins on disk, named `~@file name.txt.br` and `~@file name.txt.gz`.

Registering a route for the literal string `%7E%40file%20name.txt`, or keying a lookup on it, is not decoding. Validation asks for the file under spellings drawn per run, so it fails.

## Compression

Identical to the plain [`static` profile](../static/implementation/#compression): compression is **optional** and must come from standard middleware on **production** entries, while serving the pre-compressed `.br`/`.gz` files already on disk is allowed for every entry type. **Tuned** entries are unrestricted.

## Port, ALPN, and certificates

- **Port**: 8081 (distinct from 8080 plaintext and 8443 which is dedicated to HTTP/2 / HTTP/3 profiles), shared with the `json-tls` profile
- **ALPN**: advertise `http/1.1` only. HTTP/1.1-only clients (wrk) negotiate correctly and never upgrade to h2.
- **Certificates**: the same PEM files used by `json-tls` / `baseline-h2` / `static-h2`, mounted at `/certs/server.crt` and `/certs/server.key`. Frameworks typically read them via environment variables (`TLS_CERT`, `TLS_KEY`) or a hardcoded path, same pattern as the other TLS tests.

## What it measures

- Everything [Static Files](../static/implementation/#what-it-measures) measures
- **Path decoding** - one request in 21 names its file with percent-encoded characters
- **TLS handshake cost amortized over keep-alive** - connections are long-lived at 1,024 concurrent
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
| Endpoint | 21 URIs under `/static/*` (one percent-encoded) |
| Transport | HTTP/1.1 over TLS |
| Port | 8081 |
| ALPN | `http/1.1` |
| Connections | 1,024 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | wrk + `requests/static-rotate.lua` |
| Certificates | mounted at `/certs/server.crt` + `/certs/server.key` |
