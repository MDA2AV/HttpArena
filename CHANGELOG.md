# Changelog

Notable changes to test profiles, scoring, and validation.

## 2026-04-10

### JSON test — variable item count and multiplier

The JSON endpoint changed from `GET /json` to `GET /json/{count}?m=N`, where `count` (1–50) controls how many items the server returns and `m` (integer, default 1) is a multiplier applied to the total field: `total = price * quantity * m`. Each benchmark template uses a different `m` value, making every response unique and preventing response caching. All dataset fields are now integers (no floats) to avoid culture-specific decimal formatting and floating-point rounding issues.

### Compression test — merged into JSON

The standalone `/compression` endpoint has been removed. Compression is now tested through the JSON endpoint by sending `Accept-Encoding: gzip, br` in the request headers. The compression middleware handles on-the-fly compression when the header is present. Two separate benchmark profiles use the same endpoint:
- **json** — no `Accept-Encoding`, measures pure serialization
- **json-compressed** — with `Accept-Encoding: gzip, br`, measures serialization + compression

This eliminates the need for pre-loaded dataset files (`dataset-large.json`, `dataset-{100,1000,1500,6000}.json`) and the separate `/compression/{count}` route.

### Upload test — variable payload size

The upload benchmark now rotates across four payload sizes: 500 KB, 2 MB, 10 MB, and 20 MB (using gcannon `-r 5`). Previously only a fixed 20 MB payload was sent. Validation tests all four sizes. No endpoint change — `POST /upload` still returns the byte count.

### Async DB test — variable limit

The async-db endpoint now accepts a `limit` query parameter: `GET /async-db?min=10&max=50&limit=N`. The benchmark rotates across limits 5, 10, 20, 35, and 50 (using gcannon `-r 25` to balance requests evenly). Validation uses different limits (7, 18, 33, 50) **and** different price ranges (`min`/`max`) per request to prevent hardcoded responses. The SQL `LIMIT` clause is now parameterized instead of hardcoded to 50.

### All data fields changed to integers

All numeric fields in the datasets and database are now integers — no floats or doubles anywhere. This eliminates floating-point rounding inconsistencies, locale-specific decimal formatting issues, and type mismatch errors with parameterized database queries.

- **dataset.json**: `price` (was float → int 1–500), `rating.score` (was float → int 1–50)
- **dataset-large.json**: same changes across 6,000 items
- **pgdb-seed.sql**: `price` and `rating_score` columns changed from `DOUBLE PRECISION` to `INTEGER`
- **JSON `total` field**: now `price * quantity * m` — pure integer multiplication, no rounding needed
- All frameworks updated: query parameters, DB readers, and model types changed from float/double to int/long

### TCP Fragmentation test — removed

The `tcp-frag` test profile has been removed. With loopback MTU now set to 1500 (realistic Ethernet) for all tests, every benchmark already exercises TCP segmentation under production-like conditions. The extreme MTU 69 stress test no longer adds meaningful signal.

### Assets-4 / Assets-16 tests — removed

The `assets-4` and `assets-16` workload profiles have been removed. These were mixed static/JSON/compression tests constrained to 4 and 16 CPUs respectively. The `static` and `json` isolated profiles already cover file serving and serialization independently, and the `api-4`/`api-16` profiles cover resource-constrained workloads.

### Static files — realistic file sizes

Regenerated all 20 static files with varied sizes typical of a modern web application. Files now have realistic size distribution — large bundles (vendor.js 300 KB, app.js 200 KB, components.css 200 KB) alongside small utilities (reset.css 8 KB, analytics.js 12 KB, logo.svg 15 KB). Content uses realistic repetition patterns for compression ratios matching real-world code.

| Category | Files | Size range |
|----------|-------|------------|
| CSS | 5 | 8–200 KB |
| JavaScript | 5 | 12–300 KB |
| HTML | 2 | 55–120 KB |
| Fonts | 2 | 18–22 KB |
| SVG | 2 | 15–70 KB |
| Images | 3 | 6–45 KB |
| JSON | 1 | 3 KB |

Total: ~842 KB original, ~219 KB brotli-compressed, ~99 KB binary.

### Static files — pre-compressed files on disk

All 15 text-based static files now ship with pre-compressed variants alongside the originals:

- `.gz` — gzip at maximum level (level 9)
- `.br` — brotli at maximum level (quality 11)

Compression ratios: gzip 64–93%, brotli 68–94%. These files allow frameworks that support pre-compressed file serving (e.g., Nginx `gzip_static`/`brotli_static`, ASP.NET `MapStaticAssets`) to serve compressed responses with **zero CPU overhead** — no on-the-fly compression needed.

Binary files (woff2, webp) do not have pre-compressed variants since they are already compressed formats.

### Static test — load generator changed to wrk

The H/1.1 static file test now uses **wrk** with a Lua rotation script instead of gcannon. wrk achieves higher throughput on large-response workloads (~20% more bandwidth than gcannon's io_uring buffer ring path), ensuring the load generator is not the bottleneck. The Lua script rotates across all 20 static file paths with `Accept-Encoding: br;q=1, gzip;q=0.8`.

### Loopback MTU set to 1500

All benchmark scripts now set the loopback interface MTU to 1500 (realistic Ethernet) before benchmarking and restore to 65536 on exit. This ensures TCP segmentation behavior matches real-world production networks.

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
