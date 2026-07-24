---
title: Implementation Guidelines
---
{{< type-rules production="Must load files from disk on every request. No in-memory caching, no memory-mapped files, no pre-loaded file buffers. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving pre-compressed `.br`/`.gz` variants from disk **is allowed**, but only through a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`). No custom file-suffix lookup logic." tuned="May cache files in memory at startup, use memory-mapped files, pre-rendered response headers, or any caching strategy. May serve pre-compressed files (.gz, .br) from disk via any mechanism. Free to use any compression approach." engine="No specific rules. Ranked separately from frameworks." >}}


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
- File serving strategy efficiency (disk I/O vs caching, depending on type)
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
