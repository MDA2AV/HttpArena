---
title: Implementation Guidelines
---
{{< type-rules production="Must use an async PostgreSQL driver with standard connection pooling. Pool size should follow common defaults (e.g. CPU count × 4)." tuned="May use custom pool sizes, prepared statement caching, or driver-specific optimizations beyond defaults." engine="No specific rules." >}}


The Async Database profile measures how efficiently a framework handles concurrent database queries over a network connection. Unlike the [synchronous SQLite `/db` endpoint](../../database) (CPU-bound, tested as the `sync-db` profile), this test exercises async I/O scheduling, connection pooling, and async Postgres driver efficiency.

**This test is for framework-type entries only** - engines (nginx, h2o, etc.) are excluded.

**Connections:** 1,024

## How it works

1. A Postgres container runs alongside the framework container on the same host, listening on `localhost:5432`
2. The framework reads the `DATABASE_URL` environment variable at startup and initializes a connection pool
3. On each `GET /async-db?min=10&max=50&limit=20` request, the framework:
   - Parses `min`, `max` (floats, default `10` and `50`) and `limit` (integer, default `50`, max `50`) query parameters
   - Executes an async range query with the parameterized `LIMIT` against the Postgres `items` table
   - Restructures `rating_score` and `rating_count` into a nested `rating` object
   - Serializes the result as JSON
4. Returns `Content-Type: application/json`

## What it measures

- **Async I/O scheduling** - how efficiently the event loop handles network round-trips to Postgres while serving concurrent HTTP requests
- **Connection pooling** - maintaining and multiplexing a pool of Postgres connections across thousands of concurrent requests
- **Async driver quality** - the efficiency of the language's async Postgres driver (e.g., `asyncpg`, `tokio-postgres`, `pg`)
- **Result parsing + JSON serialization** - converting Postgres rows to structured JSON with nested objects

## Database schema

The `items` table in Postgres (100,000 rows, identical logical data to the SQLite `benchmark.db`):

```sql
CREATE TABLE items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    price INTEGER NOT NULL,
    quantity INTEGER NOT NULL,
    active BOOLEAN NOT NULL,
    tags JSONB NOT NULL,
    rating_score INTEGER NOT NULL,
    rating_count INTEGER NOT NULL
);
-- No index on price - forces sequential scan
```

Key differences from the SQLite schema:
- `active` is `BOOLEAN` (not `INTEGER 0/1`) - no conversion needed
- `tags` is `JSONB` (not `TEXT`) - no JSON string parsing needed

## SQL query

```sql
SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
FROM items
WHERE price BETWEEN $1 AND $2
LIMIT $3
```

## Expected response

```
GET /async-db?min=10&max=50&limit=20 HTTP/1.1
```

```json
{
  "items": [
    {
      "id": 42,
      "name": "Alpha Widget 42",
      "category": "electronics",
      "price": 29.99,
      "quantity": 5,
      "active": true,
      "tags": ["fast", "new"],
      "rating": { "score": 4.2, "count": 127 }
    }
  ],
  "count": N
}
```

The `count` field must be dynamically computed from the number of returned items, not hardcoded.

When Postgres is unavailable or the query returns no rows, return:

```json
{"items":[],"count":0}
```

## Environment variables

The benchmark runner provides these environment variables to your container:

| Variable | Value | Description |
|----------|-------|-------------|
| `DATABASE_URL` | `postgres://bench:bench@localhost:5432/benchmark` | Postgres connection string. Always read from this - never hardcode. |
| `DATABASE_MAX_CONN` | `256` | Maximum connections allowed by the Postgres instance. Use this to size your connection pool. May be lower for CPU-constrained tests (e.g. API-4, API-16). |

## Implementation notes

- **Async driver required** - use your language's async Postgres driver (e.g., `asyncpg` for Python, `tokio-postgres` for Rust, `pg` for Node.js, `r2d2`/`deadpool` for connection pools)
- **Connection pool** - initialize a pool at startup. Read `DATABASE_MAX_CONN` to set your pool size. A good default is `min(DATABASE_MAX_CONN, num_cpus)` or a fixed value like 64-128
- **Prepared statements** - prepare the query once per connection, reuse across requests
- **Default parameters** - if `min` or `max` query parameters are missing, default to `10` and `50` respectively. If `limit` is missing, default to `50`. Clamp `limit` to the range 1–50
- **Tags are JSONB** - Postgres returns them as native JSON, no string parsing needed (unlike the SQLite `/db` endpoint)

## Important: environment variables and initialization

**Never hardcode** connection details. Always read `DATABASE_URL` for the connection string and `DATABASE_MAX_CONN` for pool sizing.

The benchmark runner starts Postgres and waits for the seed data to be fully loaded before starting your framework container. By the time your server starts, Postgres is ready and accepting connections.

**Recommended: lazy initialization with retry.** As a safety net, handle the case where the initial connection fails gracefully. Do not crash the server - return the empty fallback response and retry on the next request.

```
# Pseudocode
pg_pool = null

on_startup:
    try: pg_pool = connect(DATABASE_URL)
    catch: pg_pool = null  # don't crash

on_request /async-db:
    if pg_pool is null:
        try: pg_pool = connect(DATABASE_URL)
        catch: return {"items":[],"count":0}
    try: return query(pg_pool)
    catch: pg_pool = null; return {"items":[],"count":0}
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /async-db?min=X&max=Y&limit=N` |
| Limits | 5, 10, 20, 35, 50 (rotated with `-r 25`) |
| Connections | 1,024 |
| Pipeline | 1 |
| Duration | 10s |
| Runs | 3 (best taken) |
| Database | Postgres 17, 100,000 rows, no index on `price` |
