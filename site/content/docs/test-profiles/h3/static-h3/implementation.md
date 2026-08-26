---
title: Implementation Guidelines
seo_title: "Static File Serving Benchmark (HTTP/3): Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/3 static file benchmark."
---
{{< type-rules standard="File contents may be served from memory, but the cache must be the framework's own - a documented static file handler with whatever caching it comes with. A cache assembled in the entry does not count: no reading the directory into a map at startup, no pre-loaded buffers, no mapping the files by hand. The cache must also follow the disk: replace a file and the next response must carry the new bytes. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving the pre-compressed `.br`/`.gz` variants that sit on disk next to the originals **is allowed**, by a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`, Hono `serveStatic({ precompressed: true })`) where the framework has one, and otherwise by selecting the variant in the entry off `Accept-Encoding`. Those bytes already exist, so choosing one is a file read rather than compression - which is why this is allowed while compressing by hand is not. The response must carry the original file's `Content-Type`, the matching `Content-Encoding`, and must still follow the disk." tuned="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. Pre-rendered response headers stay allowed, as does serving pre-compressed .gz/.br variants from disk via any mechanism, with any compression approach." engine="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. No other restrictions. Ranked separately from frameworks." infrastructure="Configuration is free, including sendfile, open_file_cache, mmap and in-memory caching - serving files fast from a tuned cache is the job. Pre-compressed .br/.gz variants may be served through the server's own mechanism (nginx gzip_static / brotli_static, Caddy precompressed). Bodies must come from the mounted static directory; a handler that synthesizes them is not serving files. QUIC and HTTP/3 must come from the server's own implementation or a standard library it is built against, with QUIC parameter tuning allowed." >}}


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
