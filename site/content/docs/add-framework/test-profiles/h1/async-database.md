---
title: Async Database (Postgres)
---

The Async Database profile measures how efficiently a framework handles concurrent database queries over a network connection. Unlike the [synchronous SQLite `/db` endpoint](../database) (CPU-bound, tested only within mixed workloads), this test exercises async I/O scheduling, connection pooling, and async Postgres driver efficiency.

**This test is for framework-type entries only** — engines (nginx, h2o, etc.) are excluded.

**Connections:** 256, 1,024, 4,096

## How it works

1. A Postgres container runs alongside the framework container on the same host, listening on `localhost:5432`
2. The framework reads the `DATABASE_URL` environment variable at startup and initializes a connection pool
3. On each `GET /pgdb?min=10&max=50` request, the framework:
   - Parses `min` and `max` query parameters (both floats, default `10` and `50`)
   - Executes an async range query with `LIMIT 50` against the Postgres `items` table
   - Restructures `rating_score` and `rating_count` into a nested `rating` object
   - Serializes the result as JSON
4. Returns `Content-Type: application/json`

## What it measures

- **Async I/O scheduling** — how efficiently the event loop handles network round-trips to Postgres while serving concurrent HTTP requests
- **Connection pooling** — maintaining and multiplexing a pool of Postgres connections across thousands of concurrent requests
- **Async driver quality** — the efficiency of the language's async Postgres driver (e.g., `asyncpg`, `tokio-postgres`, `pg`)
- **Result parsing + JSON serialization** — converting Postgres rows to structured JSON with nested objects

## Database schema

The `items` table in Postgres (100,000 rows, identical logical data to the SQLite `benchmark.db`):

```sql
CREATE TABLE items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    price DOUBLE PRECISION NOT NULL,
    quantity INTEGER NOT NULL,
    active BOOLEAN NOT NULL,
    tags JSONB NOT NULL,
    rating_score DOUBLE PRECISION NOT NULL,
    rating_count INTEGER NOT NULL
);
-- No index on price — forces sequential scan
```

Key differences from the SQLite schema:
- `active` is `BOOLEAN` (not `INTEGER 0/1`) — no conversion needed
- `tags` is `JSONB` (not `TEXT`) — no JSON string parsing needed

## SQL query

```sql
SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
FROM items
WHERE price BETWEEN $1 AND $2
LIMIT 50
```

## Expected response

```
GET /pgdb?min=10&max=50 HTTP/1.1
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

## Connection details

The framework receives the Postgres connection string via the `DATABASE_URL` environment variable:

```
DATABASE_URL=postgres://bench:bench@localhost:5432/benchmark
```

## Implementation notes

- **Async driver required** — use your language's async Postgres driver (e.g., `asyncpg` for Python, `tokio-postgres` for Rust, `pg` for Node.js, `r2d2`/`deadpool` for connection pools)
- **Connection pool** — initialize a pool at startup. Recommended pool size: number of CPU cores or 16–32 connections
- **Prepared statements** — prepare the query once per connection, reuse across requests
- **Default parameters** — if `min` or `max` query parameters are missing, default to `10` and `50` respectively
- **Tags are JSONB** — Postgres returns them as native JSON, no string parsing needed (unlike the SQLite `/db` endpoint)

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /pgdb` |
| Connections | 256, 1,024, 4,096 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Database | Postgres 17, 100,000 rows, no index on `price` |
