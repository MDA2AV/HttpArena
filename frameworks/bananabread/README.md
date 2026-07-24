# bananabread

A HttpArena entry for **Seagreen** — a TypeScript port of [GenHTTP](https://github.com/Kaliumhexacyanoferrat/GenHTTP)
on the [Bun](https://bun.sh) runtime (the TypeScript sibling of the Kotlin port, `fishcake`/CodeGreen).
It runs GenHTTP's own internal HTTP/1.1 engine, built on `Bun.listen` raw TCP (not `Bun.serve`).

## Stack

- **Language:** TypeScript / Bun
- **Framework:** Seagreen (TypeScript port of GenHTTP)
- **Engine:** Seagreen internal engine (raw TCP via `Bun.listen`)
- **Database:** Bun's built-in SQL client (`Bun.SQL`) for PostgreSQL
- **Multi-core:** one worker process per core, sharing the port via `SO_REUSEPORT`
- **Build:** none — Bun runs the TypeScript directly; Seagreen is cloned at image build time

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` |
| `/baseline11` | GET / POST | Sums `a` + `b` (POST adds a body value) |
| `/baseline2` | GET | Sums `a` + `b` |
| `/json/{count}` | GET | Processes `count` dataset items; `?m=` scales the total (default 1) |
| `/upload` | POST | Streams the body, returns the byte count |
| `/async-db` | GET | `price BETWEEN min AND max` range query |
| `/crud/items` | GET | Paged listing by category |
| `/crud/items/{id}` | GET | Cached read (`X-Cache: HIT\|MISS`) |
| `/crud/items` | POST | Upsert → `201 Created` |
| `/crud/items/{id}` | PUT | Update, `404` when unknown |

Declared profiles (`meta.json`): `baseline`, `pipelined`, `limited-conn`, `json`, `upload`,
`async-db`, `crud`, `api-4`, `api-16`. TLS/HTTP-2, compression, static files, websockets and
gRPC are omitted (those Seagreen modules are not ported yet).

## Notes

- The single-item CRUD read uses an in-process 200 ms TTL cache (mirrors GenHTTP's `MemoryCache`).
- `DATABASE_URL`, `DATASET_PATH` follow the standard HttpArena contract; without `DATABASE_URL`
  the database-backed endpoints degrade gracefully (empty results / `404`).
- The image clones Seagreen from `main` (public repo `dotnet-web-stack/Seagreen`), so that branch
  must contain the current engine (including the `workers()` API and the multi-worker spawn fix).
