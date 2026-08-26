---
title: Implementation Guidelines
seo_title: "Static File Serving Benchmark (HTTP/2): Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/2 static file benchmark."
---
{{< type-rules standard="File contents may be served from memory, but the cache must be the framework's own - a documented static file handler with whatever caching it comes with. A cache assembled in the entry does not count: no reading the directory into a map at startup, no pre-loaded buffers, no mapping the files by hand. The cache must also follow the disk: replace a file and the next response must carry the new bytes. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving the pre-compressed `.br`/`.gz` variants that sit on disk next to the originals **is allowed**, by a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`, Hono `serveStatic({ precompressed: true })`) where the framework has one, and otherwise by selecting the variant in the entry off `Accept-Encoding`. Those bytes already exist, so choosing one is a file read rather than compression - which is why this is allowed while compressing by hand is not. The response must carry the original file's `Content-Type`, the matching `Content-Encoding`, and must still follow the disk." tuned="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. Pre-rendered response headers stay allowed, as does serving pre-compressed .gz/.br variants from disk via any mechanism, with any compression approach." engine="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. No other restrictions. Ranked separately from frameworks." infrastructure="Configuration is free, including sendfile, open_file_cache, mmap and in-memory caching - serving files fast from a tuned cache is the job. Pre-compressed .br/.gz variants may be served through the server's own mechanism (nginx gzip_static / brotli_static, Caddy precompressed). Bodies must come from the mounted static directory; a handler that synthesizes them is not serving files. HTTP/2 must be the server's own implementation, with stream and window tuning allowed." >}}


Serves 20 static files of various types and sizes over HTTP/2 with TLS, simulating a realistic browser page load with multiplexed streams.

**Connections:** 256, 1,024
**Concurrent streams per connection:** 32

## Workload

The load generator ([h2load](https://nghttp2.org/documentation/h2load-howto.html)) requests 20 static files in a round-robin pattern across multiplexed streams. All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`.

- **CSS** (5 files, 8–55 KB): `reset.css`, `layout.css`, `theme.css`, `components.css`, `utilities.css`
- **JavaScript** (5 files, 15–400 KB): `analytics.js`, `helpers.js`, `app.js`, `vendor.js`, `router.js`
- **HTML** (2 files, 5–8 KB): `header.html`, `footer.html`
- **Fonts** (2 files, 20–25 KB): `regular.woff2`, `bold.woff2`
- **SVG** (2 files, 12–55 KB): `logo.svg`, `icon-sprite.svg`
- **Images** (3 files, 15–120 KB): `hero.webp`, `thumb1.webp`, `thumb2.webp`
- **JSON** (1 file, 3 KB): `manifest.json`

Total payload: ~1.16 MB across 20 files (~966 KB compressible text + ~200 KB binary).

Pre-compressed versions (`.gz`, `.br`) are available on disk. See the [HTTP/1.1 static files compression section](/docs/test-profiles/h1/isolated/static/implementation/#compression) for full compression rules.

## What it measures

- Static file serving throughput over HTTP/2
- HTTP/2 multiplexing efficiency with varied response sizes
- Content-Type handling for different file types
- File serving strategy efficiency - how well the framework moves bytes to the client (sendfile, readahead, buffer sizing, and its own caching where it has any)
- TLS overhead with realistic mixed payloads
- Compression efficiency (optional - reduces I/O at the cost of CPU)

## Expected request/response

```
GET /static/reset.css HTTP/2
```

```
HTTP/2 200 OK
Content-Type: text/css

(file contents)
```

```
GET /static/app.js HTTP/2
```

```
HTTP/2 200 OK
Content-Type: application/javascript

(file contents)
```

## How it differs from baseline-h2

| | Baseline (HTTP/2) | Static Files (HTTP/2) |
|---|---|---|
| Endpoint | Single `GET /baseline2` | 20 different `/static/*` URIs |
| Response size | ~2 bytes | 3–400 KB (varied) |
| Content types | `text/plain` | CSS, JS, HTML, fonts, SVG, WebP, JSON |
| h2load mode | Single URI | Multi-URI (`-i` flag, round-robin) |

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | 20 URIs under `/static/*` |
| Connections | 256, 1,024 |
| Streams per connection | 32 (`-m 32`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load with `-i` (multi-URI) |
