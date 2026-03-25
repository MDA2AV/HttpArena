---
title: Database Query
---

The Database Query endpoint measures how efficiently a framework handles SQLite queries, result parsing, and JSON serialization. It is not a standalone benchmark profile — it is exercised as part of the [Mixed Workload](../mixed) profile.

## How it works

1. At startup, the server opens `/data/benchmark.db` — a SQLite database with 100,000 rows and **no index on `price`**, forcing a full table scan on every query
2. On each `GET /db?min=10&max=50` request, the server:
   - Parses `min` and `max` query parameters (both floats, default `10` and `50`)
   - Executes a range query with `LIMIT 50`
   - Parses the `tags` column from a JSON string into an array
   - Converts `active` from SQLite integer (0/1) to boolean
   - Restructures `rating_score` and `rating_count` into a nested `rating` object
   - Serializes the result as JSON
3. Returns `Content-Type: application/json`

## What it measures

- **SQLite query performance** — full table scan over 100K rows with a range filter
- **Result parsing** — converting SQLite row data to structured JSON (tags parsing, type coercion)
- **JSON serialization** — building and serializing a response with nested objects
- **Concurrency under I/O** — handling concurrent database reads from multiple connections

## Database schema

The `items` table in `benchmark.db`:

```sql
CREATE TABLE items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    price REAL NOT NULL,
    quantity INTEGER NOT NULL,
    active INTEGER NOT NULL,
    tags TEXT NOT NULL,          -- JSON array stored as string, e.g. '["fast","new"]'
    rating_score REAL NOT NULL,
    rating_count INTEGER NOT NULL
)
-- No index on price — forces full table scan
```

## SQL query

All implementations use the same query:

```sql
SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
FROM items
WHERE price BETWEEN ? AND ?
LIMIT 50
```

The `min` and `max` parameters are bound as floats.

## Expected response

```
GET /db?min=10&max=50 HTTP/1.1
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

Key transformations from raw SQLite row to JSON response:

| SQLite column | JSON field | Transformation |
|---------------|-----------|----------------|
| `active` | `active` | Integer 0/1 → boolean |
| `tags` | `tags` | JSON string → parsed array |
| `rating_score` | `rating.score` | Nested into `rating` object |
| `rating_count` | `rating.count` | Nested into `rating` object |

The `count` field must be dynamically computed from the number of returned items (e.g. `len(items)`, `items.length`, `items.size()`), not hardcoded.

When the database is unavailable or the query returns no rows, return:

```json
{"items":[],"count":0}
```

## Implementation notes

- **Thread safety** — use thread-local or per-worker database connections. SQLite connections should not be shared across threads.
- **Read-only mode** — open the database in read-only mode where possible (`SQLITE_OPEN_READONLY` or equivalent).
- **Prepared statements** — prepare the query once at startup and reuse per-thread to avoid repeated parsing.
- **Default parameters** — if `min` or `max` query parameters are missing, default to `10` and `50` respectively.
