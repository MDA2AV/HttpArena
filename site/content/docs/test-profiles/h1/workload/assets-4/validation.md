---
title: Validation
---

The Assets-4 test validates that the server correctly handles conditional compression. Subscribing to `assets-4` or `assets-16` triggers these checks:

## Compression checks

1. **JSON without gzip** — `GET /json` (no `Accept-Encoding` header): response must be uncompressed, no `Content-Encoding` header
2. **JSON with gzip** — `GET /json` with `Accept-Encoding: gzip`: response must have `Content-Encoding: gzip`
3. **Text file without gzip** — `GET /static/app.js` (no `Accept-Encoding` header): response size must match file on disk, no `Content-Encoding` header
4. **Text file with gzip** — `GET /static/app.js` with `Accept-Encoding: gzip`: response must have `Content-Encoding: gzip` and be smaller than the original file
5. **Binary file (webp) with gzip** — `GET /static/hero.webp` with `Accept-Encoding: gzip`: response must NOT have `Content-Encoding: gzip`, size must match file on disk
6. **Binary file (woff2) with gzip** — `GET /static/regular.woff2` with `Accept-Encoding: gzip`: response must NOT have `Content-Encoding: gzip`, size must match file on disk
7. **SVG with gzip** — `GET /static/icon-sprite.svg` with `Accept-Encoding: gzip`: either compressed or uncompressed is accepted

## Prerequisite checks

The following endpoint validations are also required (inherited from the individual test profiles):

- `/json` — [JSON Processing validation](../../../isolated/json-processing/validation)
- `/static/*` — [Static Files validation](../../../isolated/static/validation)
