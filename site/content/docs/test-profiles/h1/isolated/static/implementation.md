---
title: Implementation Guidelines
---
{{< type-rules production="Must load files from disk on every request. No in-memory caching, no memory-mapped files, no pre-loaded file buffers. Compression must use the framework's standard middleware or built-in static file handler — no handmade compression code." tuned="May cache files in memory at startup, use memory-mapped files, pre-rendered response headers, or any caching strategy. May serve pre-compressed files (.gz, .br) from disk. Free to use any compression approach." engine="No specific rules." >}}


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

**Compression is optional.** Frameworks that don't compress will serve files uncompressed — there is no penalty or validation failure. However, frameworks that do compress will benefit from reduced I/O, which naturally improves throughput.

- **Text files** (CSS, JS, HTML, SVG, JSON): good candidates for compression (68–94% size reduction with brotli)
- **Binary files** (woff2, webp): already compressed formats — servers should skip compression for these
- **Pre-compressed files**: `.gz` and `.br` versions are available on disk. Frameworks that support serving pre-compressed files (e.g., Nginx `gzip_static`/`brotli_static`) can serve these directly with zero CPU overhead

**Production rule:** compression must use the framework's standard middleware or built-in static file handler (e.g., Nginx `gzip on`, ASP.NET response compression middleware). No handmade compression code.

**Tuned rule:** free to use any approach — custom compression, pre-compressed file serving, etc.

## What it measures

- Static file serving throughput over HTTP/1.1
- Content-Type handling for different file types
- File serving strategy efficiency (disk I/O vs caching, depending on type)
- Response efficiency with varied payload sizes
- Compression efficiency (optional — reduces I/O at the cost of CPU)

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
