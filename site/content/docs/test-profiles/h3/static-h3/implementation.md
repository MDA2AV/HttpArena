---
title: Implementation Guidelines
---
{{< type-rules production="Must load files from disk on every request. No in-memory caching, no memory-mapped files, no pre-loaded file buffers. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving pre-compressed `.br`/`.gz` variants from disk **is allowed**, but only through a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`). No custom file-suffix lookup logic." tuned="May cache files in memory at startup, use memory-mapped files, pre-rendered response headers, or any caching strategy. May serve pre-compressed files (.gz, .br) from disk via any mechanism. Free to use any compression approach." engine="No specific rules. Ranked separately from frameworks." >}}


The HTTP/3 Static Files profile serves 20 static files of various types over QUIC, simulating a browser loading page assets over HTTP/3.

**Connections:** 64

## How it works

1. The load generator ([h2load-h3](/docs/load-generators/h3/h2load-h3/)) connects over HTTP/3 (QUIC) on port 8443
2. Cycles through 20 URIs from `requests/static-h2-uris.txt` (same file set as the HTTP/2 static test)
3. All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`
4. Each request fetches a different static file - CSS, JavaScript, HTML, fonts, SVGs, WebP images, and JSON
5. The server returns file contents with the correct `Content-Type`, optionally compressed

## What it measures

- **HTTP/3 static asset serving** - mixed content types and sizes over QUIC
- **QUIC multiplexing** - how well the framework handles varied concurrent requests
- **Content-Type handling** - correct MIME type mapping across file types
- **Compression efficiency** (optional) - reduces payload size at the cost of CPU

## Static files

20 files (~1.16 MB total, ~966 KB compressible text + ~200 KB binary):

| Type | Files | Examples |
|------|-------|---------|
| CSS | 5 | `reset.css`, `layout.css`, `theme.css` |
| JavaScript | 5 | `app.js`, `vendor.js`, `router.js` |
| HTML | 2 | `header.html`, `footer.html` |
| Fonts | 2 | `regular.woff2`, `bold.woff2` |
| SVG | 2 | `logo.svg`, `icon-sprite.svg` |
| WebP | 3 | `hero.webp`, `thumb1.webp`, `thumb2.webp` |
| JSON | 1 | `manifest.json` |

Pre-compressed versions (`.gz`, `.br`) are available on disk. See the [HTTP/1.1 static files compression section](/docs/test-profiles/h1/isolated/static/implementation/#compression) for full compression rules.

## Expected request/response

```
GET /static/logo.svg HTTP/3
```

```
HTTP/3 200 OK
Content-Type: image/svg+xml

(file contents)
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | 20 URIs under `/static/*` |
| Connections | 64 |
| Streams per connection | 64 (`-m 64`) |
| Threads | 64 (`H3THREADS`) |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | h2load-h3 (`--alpn-list=h3 -i …`) |
| Port | 8443 (TLS + QUIC) |
