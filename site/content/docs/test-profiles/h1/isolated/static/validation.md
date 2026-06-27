---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `static` test.

## Content-Type headers

Verifies correct `Content-Type` headers for representative file types:

- `GET /static/reset.css` - expects `Content-Type: text/css`
- `GET /static/app.js` - expects `Content-Type: application/javascript`
- `GET /static/manifest.json` - expects `Content-Type: application/json`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

## File size verification (uncompressed)

Requests all 20 static files **without** `Accept-Encoding` and compares the response size against the actual file size on disk. All 20 files must match exactly. This ensures the server returns uncompressed content when no compression is requested.

`reset.css`, `layout.css`, `theme.css`, `components.css`, `utilities.css`, `analytics.js`, `helpers.js`, `app.js`, `vendor.js`, `router.js`, `header.html`, `footer.html`, `regular.woff2`, `bold.woff2`, `logo.svg`, `icon-sprite.svg`, `hero.webp`, `thumb1.webp`, `thumb2.webp`, `manifest.json`

## Compression verification

Requests all 20 static files **with** `Accept-Encoding: br;q=1, gzip;q=0.8` and checks:

- If the server returns a `Content-Encoding` header (br or gzip), the decompressed response size must match the original file size on disk
- If the server does not compress a file, it is counted as skipped (not a failure - compression is optional)

**PASS** if all compressed files decompress to the correct size. **SKIP** if the server does not compress any files. **FAIL** if any compressed file decompresses to the wrong size.

## 404 for nonexistent file

Sends `GET /static/nonexistent.txt` and verifies the server returns **HTTP 404**.

## Static freshness (no pre-caching)

Confirms the server reflects on-disk changes to static files instead of permanently pre-loading them into memory. `engine` and `infrastructure` types are ranked separately and **exempt** — the check is skipped for them. It applies to every other type, in both `standard` and `tuned` modes.

Using `reset.css`, the probe:

1. **Primes** the server by requesting the original file through every `Accept-Encoding` (`identity`, `gzip`, `br`), so any lazy first-request cache is populated with the pre-change bytes.
2. **Rewrites** `reset.css` — and its precompressed `.gz`/`.br` siblings, if present — on disk with a unique sentinel token **while the server is running**.
3. **Polls** once per second, re-requesting the file under each `Accept-Encoding` and decoding the response by its `Content-Encoding`, until every encoding returns the new token or the grace window elapses.
4. **Restores** the original files afterwards (also via the cleanup trap if the run aborts).

The grace window is `STATIC_FRESHNESS_GRACE` (default **30s**). A short revalidating cache (e.g. `fasthttp.FS`, nginx `open_file_cache`) legitimately reflects the change after a brief delay and passes; a permanent pre-cache (startup load or build-time manifest) never reflects it and fails — the window is what separates the two.

**PASS** if every served encoding reflects the change within the window (reported as immediate when ≤1s, otherwise as a revalidating cache). **SKIP** for `engine`/`infrastructure` types, or if `reset.css` is absent. **FAIL** if any encoding still serves stale content after the grace window — permanent pre-loading/caching of static files is not allowed (`standard` or `tuned`).
