---
title: Implementation Guidelines
seo_title: "Static File Serving Benchmark (HTTP/1.1) — Implementation Guide"
description: "Endpoint contract, request and response shapes, and the anti-cheat constraints a framework must satisfy for the HTTP/1.1 static file benchmark."
---
{{< type-rules standard="File contents may be served from memory, but the cache must be the framework's own - a documented static file handler with whatever caching it comes with. A cache assembled in the entry does not count: no reading the directory into a map at startup, no pre-loaded buffers, no mapping the files by hand. The cache must also follow the disk: replace a file and the next response must carry the new bytes. Compression must use the framework's standard middleware or built-in static file handler - no handmade compression code. Serving pre-compressed `.br`/`.gz` variants from disk **is allowed**, but only through a documented framework API (e.g. ASP.NET `MapStaticAssets`, nginx `gzip_static` / `brotli_static`, Caddy `precompressed`). No custom file-suffix lookup logic - a framework that ships no static file handling of its own serves the files uncompressed, which is the measurement rather than a penalty." tuned="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. Pre-rendered response headers stay allowed, as does serving pre-compressed .gz/.br variants from disk via any mechanism, with any compression approach." engine="File contents may be served from memory, the same rule as Standard: the cache must be the framework's own rather than one assembled in the entry, and it must follow the disk - replace a file and the next response must carry the new bytes. No other restrictions." infrastructure="Configuration is free, including sendfile, open_file_cache, mmap and in-memory caching - serving files fast from a tuned cache is the job. Pre-compressed .br/.gz variants may be served through the server's own mechanism (nginx gzip_static / brotli_static, Caddy precompressed). Bodies must come from the mounted static directory; a handler that synthesizes them is not serving files." >}}


Serves 20 static files of various types and sizes over HTTP/1.1, simulating a realistic page load with diverse file types and sizes.

**Connections:** 1,024, 4,096, 6,800

## Workload

The load generator ([wrk](https://github.com/wg/wrk)) requests 20 static files in a round-robin pattern using a Lua rotation script. All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`.

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

All requests include `Accept-Encoding: br;q=1, gzip;q=0.8`, indicating the client prefers Brotli but accepts gzip.

**Compression is optional.** Frameworks that don't compress will serve files uncompressed - there is no penalty or validation failure. However, frameworks that do compress will benefit from reduced I/O, which naturally improves throughput.

- **Text files** (CSS, JS, HTML, SVG, JSON): good candidates for compression (68–94% size reduction with brotli)
- **Binary files** (woff2, webp): already compressed formats - servers should skip compression for these
- **Pre-compressed files**: `.gz` and `.br` versions are available on disk. Frameworks that support serving pre-compressed files via a documented API (e.g. Nginx `gzip_static`/`brotli_static`, Caddy `precompressed`, ASP.NET `MapStaticAssets`) can serve these directly with zero CPU overhead - this is allowed for both **production** and **tuned** entries.

**Production rule:** compression must come from the framework's standard middleware, built-in static file handler, or its documented pre-compressed-file API. No handmade compression code, no custom suffix-lookup logic. What a framework's own handler does internally is its business - the line is what the framework gives you, not what can be written against it. A framework that ships no static file handling serves the files uncompressed, and the bandwidth shows up in its result; that is the measurement rather than a penalty.

**Tuned rule:** free to use any approach - custom compression, manual `.br`/`.gz` lookup, etc.

## What it measures

- Static file serving throughput over HTTP/1.1
- Content-Type handling for different file types
- File serving strategy efficiency - how well the framework moves bytes to the client (sendfile, readahead, buffer sizing, and its own caching where it has any)
- Response efficiency with varied payload sizes
- Compression efficiency (optional - reduces I/O at the cost of CPU)

## Expected request/response

```
GET /static/reset.css HTTP/1.1
Host: localhost:8080
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
| Connections | 1,024, 4,096, 6,800 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | wrk with Lua rotation script |
