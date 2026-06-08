---
title: Implementation Guidelines
---
{{< type-rules production="Must use a standard async Postgres driver with connection pooling. Cache-aside with 200 ms absolute TTL on single-item reads, invalidated on PUT. In-process cache is the default; multi-process runtimes (e.g. SO_REUSEPORT with one process per core) may use the provided Redis sidecar for a shared cache. No pre-warming or background refresh." tuned="May use custom pool sizes, prepared statements, multi-tier caches, or any cache backend including the Redis sidecar." engine="No specific rules." >}}

The CRUD profile benchmarks a realistic REST API with four operations against Postgres: paginated list, cached single-item read, create (upsert), and update with cache invalidation.

**This test is for framework-type entries only** - engines (nginx, h2o, etc.) are excluded.

**Connections:** 4096

## Endpoints

### GET /crud/items - Paginated list

Accepts query parameters:
- `category` (string, default `"electronics"`) - filter by category
- `page` (integer, default `1`) - page number (1-indexed)
- `limit` (integer, default `10`, max `50`) - items per page

Executes a single SQL query:

```sql
SELECT ... FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3
```

"Load-more" pagination: the response returns the items on the requested page. The `total` field reports the number of items in *this* response (equivalent to the client's `items.length`) - not the full-filter row count. A separate `SELECT COUNT(*)` was originally part of the spec but removed because concurrent writes kept the visibility map dirty, making it ~90% of Postgres CPU for a value most real-world list APIs either skip or compute out-of-band.

Returns:
```json
{
  "items": [
    {
      "id": 42,
      "name": "Alpha Widget 42",
      "category": "electronics",
      "price": 30,
      "quantity": 5,
      "active": true,
      "tags": ["fast", "new"],
      "rating": { "score": 42, "count": 127 }
    }
  ],
  "total": 10,
  "page": 1,
  "limit": 10
}
```

### GET /crud/items/{id} - Single item read (cached)

Reads a single item by ID using a cache with **200 ms** absolute expiration.

Cache backend options:

- **In-process** (e.g. `IMemoryCache`, `HashMap`, `sync.Map`) - the default. Works for single-process frameworks and for multi-threaded runtimes that share a heap.
- **Redis** (the provided sidecar at `REDIS_URL`) - for multi-process frameworks (Bun with `reusePort`, PHP FPM, Python with uWSGI workers, etc.) where a per-process cache would fragment the working set. Cache the pre-serialized JSON body so HIT responses skip re-serialization.

Behavior:
- On cache miss: query Postgres, populate cache, return item with `X-Cache: MISS` header
- On cache hit: return cached item with `X-Cache: HIT` header
- If item not found: return HTTP 404

```json
{
  "id": 1,
  "name": "Alpha Widget 1",
  "category": "electronics",
  "price": 30,
  "quantity": 5,
  "active": true,
  "tags": ["fast", "new"],
  "rating": { "score": 42, "count": 127 }
}
```

### POST /crud/items - Create item

Accepts a JSON body:
```json
{ "id": 200001, "name": "New Product", "category": "test", "price": 25, "quantity": 10 }
```

Inserts into Postgres with `ON CONFLICT (id) DO UPDATE` (upsert). Returns HTTP 201 with the created item.

### PUT /crud/items/{id} - Update item

Accepts a JSON body:
```json
{ "name": "Updated Name", "price": 30, "quantity": 5 }
```

Updates the item in Postgres and **invalidates the cache entry** for the updated ID (from whichever cache backend is in use). Returns HTTP 200 with the updated fields. Returns 404 if the item doesn't exist.

## What it measures

- **Connection pooling** - maintaining a Postgres connection pool under mixed read/write load
- **Cache-aside correctness** - cache hit/miss with TTL-based expiration and write-through invalidation, whether the cache is in-process or external
- **Query diversity** - paginated list queries mixed with high-rate single-item lookups, inserts, and updates running concurrently
- **JSON parsing and serialization** - deserializing request bodies (POST/PUT) and serializing response payloads

## Workload mix

The load generator (gcannon) rotates across 20 raw HTTP templates. Each connection reconnects every 200 requests (`-r 200`) so templates rotate within a connection's lifetime rather than sticking to whichever template it first picked.

| Operation | Templates | Weight | ID distribution |
|-----------|-----------|--------|-----------------|
| Read (GET /crud/items/{id}) | 15 | 75% | Random IDs via `{RAND:1:50000}` |
| Update (PUT /crud/items/{id}) | 3 | 15% | Random IDs via `{RAND:1:50000}` |
| List (GET /crud/items) | 1 | 5% | `category=office`, random page via `{RAND:1:10}` (OFFSET ∈ 0..90) |
| Create (POST /crud/items) | 1 | 5% | Sequential IDs via `{SEQ:100001}` - iteration 1 is pure INSERT, iterations 2+ upsert via `ON CONFLICT` (gcannon resets the counter per invocation) |

## Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `DATABASE_URL` | `postgres://bench:bench@localhost:5432/benchmark` | Postgres connection string |
| `DATABASE_MAX_CONN` | `256` | Hint for pool sizing. Frameworks should honor this rather than hardcoding. |
| `REDIS_URL` | `redis://localhost:6379` | Optional - present when the harness runs the crud profile. Use only if the framework's architecture (multi-process) needs a shared cache. |

## Parameters

| Parameter | Value |
|-----------|-------|
| Connections | 4096 |
| Pipeline | 1 |
| Requests per connection | 200 (then reconnect) |
| CPU limit (server) | 62 threads (cores 1-31, 65-95) |
| CPU limit (Redis sidecar, when used) | 2 threads (cores 0, 64), `--io-threads 2` |
| Duration | 15s per run |
| Runs | 3 (best taken) |
| Database | Postgres 18 (Debian/glibc), 100,000 rows, `max_connections=256`, tmpfs-backed |
