---
title: Implementation Guidelines
---
{{< type-rules production="Response compression must use the framework's standard middleware. No pre-compressed files on disk. Binary formats (webp, woff2) must not be compressed." tuned="May cache compressed and uncompressed versions in memory. No pre-compressed files on disk. Must serve uncompressed when Accept-Encoding: gzip is absent." engine="No pre-compressed files on disk. Must respect Accept-Encoding header presence/absence." >}}

The Assets-4 profile serves a mix of static files and JSON responses, where some requests include `Accept-Encoding: gzip` and others do not. The server must compress text-based responses on-the-fly when the header is present, skip compression for binary formats, and serve uncompressed responses when the header is absent. The server container is constrained to **4 CPUs and 16 GB memory**.

## Compression rules

1. **Text-based files** (CSS, JS, HTML, JSON): must be gzip-compressed when `Accept-Encoding: gzip` is present in the request
2. **Binary files** (webp, woff2): must NOT be compressed even when `Accept-Encoding: gzip` is present — these formats are already compressed
3. **SVG files**: server may choose to compress or not (both are accepted)
4. **No compression header**: when `Accept-Encoding: gzip` is absent, responses must always be uncompressed regardless of content type
5. **No pre-compressed files on disk**: all compression must be performed on-the-fly or cached in memory

## Caching rules

- **Production** frameworks must use standard middleware; no in-memory caching of compressed variants
- **Tuned** and **Engine** frameworks may cache both compressed and uncompressed versions in memory, but must serve the correct variant based on the request's `Accept-Encoding` header

## Request mix (20 templates)

| Category | Templates | Accept-Encoding: gzip |
|----------|-----------|-----------------------|
| Text files (JS, CSS, HTML) | 5 | Yes |
| JSON (`/json`) | 1 | Yes |
| Text files (JS, CSS, HTML) | 5 | No |
| JSON (`/json`) | 1 | No |
| Binary (webp, woff2) | 2 | Yes (server must skip) |
| Binary (webp, woff2) | 2 | No |
| SVG | 1 | Yes (either accepted) |
| SVG | 1 | No |
| Manifest JSON + CSS | 2 | No |

## Docker constraints

The server container is started with:

```
--cpuset-cpus=0-3 --memory=16g --memory-swap=16g
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoints | `/static/*`, `/json` |
| Connections | 256 |
| Pipeline | 1 |
| Requests per connection | 10 (then reconnect with next template) |
| Duration | 15s |
| Runs | 3 (best taken) |
| Templates | 20 |
| Server CPU limit | 4 |
| Server memory limit | 16 GB |
