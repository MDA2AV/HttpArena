---
title: Tuned
weight: 2
---

Tuned mode (`mode: tuned`) gives a framework entry more freedom. It can use non-default configurations, experimental flags, and optimizations that go beyond standard framework usage. Tuned entries are marked with a ring on the leaderboard and shown alongside standard ones.

## What is allowed

- Alternative JSON serializers (simd-json, sonic-json, etc.)
- Custom buffer sizes and TCP socket options
- Experimental or unstable framework flags
- Memory-mapped files (the mapping must reflect the current file on disk)
- Custom thread pools and worker configurations
- Non-default GC settings without documentation requirement
- Framework-specific performance flags not recommended for production
- Any compression approach for static files - custom compression, pre-compressed file serving, alternative compression libraries

## What is NOT allowed

- **Pre-computed response bodies** - serializing a fixed response at startup and returning the same bytes per request (e.g. caching a JSON blob and writing it back unchanged). The serialization + compression work is the workload; bypassing it defeats the measurement.
- **Response caching** - memoizing the full HTTP response body keyed by URL/params and replaying it. This is distinct from upstream data caching (DB query results, JWT verification, etc.), which remains allowed where the profile calls for it (e.g. the CRUD profile's read cache).
- **Permanent pre-caching of static files** - loading static files (or their `.gz`/`.br` siblings) into memory at startup or first request and serving them so later changes to the file on disk are *never* reflected. A short revalidating cache that picks up on-disk changes within a grace window (e.g. `fasthttp.FS`, nginx `open_file_cache`) is fine; a frozen startup or build-time-manifest cache is not. `validate.sh` enforces this with a freshness probe that rewrites the files mid-run and polls for the change for `STATIC_FRESHNESS_GRACE` seconds (default 30) — see [static implementation guidelines](/docs/test-profiles/h1/isolated/static/implementation/). Serving pre-compressed `.gz`/`.br` from disk and using any compression approach remain allowed, provided the bytes track the current on-disk file.

## What is still required

- Must use the framework's HTTP server (not a raw socket replacement)
- Must implement all endpoint specs correctly
- Must pass the validation suite
- The framework dependency must be a real, published framework

## When to choose Tuned

If your submission uses any setting or optimization that a typical production team would not use, set `mode` to tuned. If in doubt, start with standard and switch to tuned only once you add non-standard optimizations.
