---
title: Changelog
weight: 100
---

Notable changes to test profiles, scoring, validation, and the framework roster.

## 2026-04-10

### Static files — realistic file sizes

Regenerated all 20 static files with realistic sizes typical of a modern web application. Total payload increased from ~325 KB to **~1.16 MB** (966 KB text + 200 KB binary).

| Category | Files | Before | After |
|----------|-------|--------|-------|
| CSS | 5 | 3–60 KB | 8–55 KB |
| JavaScript | 5 | 8–150 KB | 15–400 KB |
| HTML | 2 | 3–4 KB | 5–8 KB |
| Fonts | 2 | 32–38 KB | 20–25 KB |
| SVG | 2 | 8–25 KB | 12–55 KB |
| Images | 3 | 18–85 KB | 15–120 KB |
| JSON | 1 | 2 KB | 3 KB |

### Static files — pre-compressed files on disk

All 15 text-based static files now ship with pre-compressed variants alongside the originals:

- `.gz` — gzip at maximum level (level 9)
- `.br` — brotli at maximum level (quality 11)

Compression ratios: gzip 73%, brotli 77%. These files allow frameworks that support pre-compressed file serving (e.g., Nginx `gzip_static`/`brotli_static`, ASP.NET `MapStaticAssets`) to serve compressed responses with **zero CPU overhead** — no on-the-fly compression needed.

Binary files (woff2, webp) do not have pre-compressed variants since they are already compressed formats.

### Static files — compression support

All static file requests now include `Accept-Encoding: br;q=1, gzip;q=0.8`. Compression is **optional** — frameworks that compress will benefit from reduced I/O, but there is no penalty for serving uncompressed.

- **Production**: must use framework's standard middleware or built-in handler. No handmade compression.
- **Tuned**: free to use any compression approach.
- **Engine**: pre-compressed files on disk allowed, must respect Accept-Encoding header presence/absence.

Validation updated: new compression verification step tests all 20 files with Accept-Encoding, verifies decompressed size matches original. PASS if correct, SKIP if server doesn't compress, FAIL if decompressed size is wrong.

### Sync DB test — removed

The `sync-db` test profile (SQLite range query over 100K rows) has been removed. The test was redundant with `json` (pure serialization) and `async-db` (real database with network I/O, connection pooling). At 8 MB, the entire database was cached in RAM regardless of mmap settings, making it essentially a JSON serialization test with constant SQLite overhead.

**Removed:**
- `sync-db` profile from benchmark scripts and validation
- `sync-db` from all 54 framework `meta.json` test arrays
- Database documentation (`test-profiles/h1/isolated/database/`)
- Sync DB tab from H/1.1 Isolated and Composite leaderboards
- `sync-db` from composite scoring formula
- `benchmark.db` volume mount from Docker containers
- Result data (`sync-db-1024.json`)

The `/db` endpoint code remains in framework source files but is no longer tested or scored.

### Compression test — accept brotli

The compression test (`GET /compression`) now accepts both gzip and brotli. The request template sends `Accept-Encoding: gzip, br` and the framework chooses which algorithm to use. Previously only gzip was accepted.

Validation updated to accept `Content-Encoding: gzip` or `Content-Encoding: br`.

### Compression test — free compression level

The compression level restriction (previously: must use fastest level, e.g., gzip level 1) has been removed. Frameworks may use **any compression level** they choose. The bandwidth-adjusted scoring formula naturally balances the throughput vs. compression ratio tradeoff.

Eligibility simplified: a framework only needs **built-in compression support** (gzip or brotli). The "configurable compression level" requirement has been dropped.

### Compression test — squared bandwidth penalty

The scoring formula for the compression test changed from a linear to a **squared** bandwidth penalty:

**Before (linear):**
```
adjusted_rps = rps x (min_bw_per_req / bw_per_req)
```

**After (squared):**
```
ratio = min_bw_per_req / bw_per_req
adjusted_rps = rps x ratio^2
```

This heavily rewards better compression. A framework with 2x the response size of the best compressor now loses **75%** of its score (was 50% with linear). This change, combined with free compression levels, means frameworks must carefully balance compression speed against compression ratio.

### Framework roster — 35 frameworks removed

Removed all disabled frameworks and those not actively maintained or relevant to the benchmark:

**Disabled (10):** drogon, gleam-mist, kemal, lithium, ntex-iouring, prologue, rocket, salvo, scotty, ulfius

**Removed (25):** blitz, bun, caddy, carno, chi, deno, django, echo, elysia, express, fastapi, fastify, fiber, flask, gin, helidon, hono, koa, nginx-openresty, node, phoenix, spring-jvm, starlette, uwebsockets, vertx

Framework directories, benchmark results, log files, and `frameworks.json` entries were all cleaned up. **hono-bun** and **ultimate-express** (Node.js) are retained.
