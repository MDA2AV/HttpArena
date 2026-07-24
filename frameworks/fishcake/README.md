# fishcake

A HttpArena entry for **CodeGreen** — a 1:1 Kotlin port of the C# [GenHTTP](https://github.com/Kaliumhexacyanoferrat/GenHTTP)
web server — running on its internal Netty-based engine. It is configured like the
sibling [`genhttp-11`](../genhttp-11) entry, rebuilt on the port's webservice stack
(Conversion + Reflection + Webservices + Layouting).

## Stack

- **Language:** Kotlin / JDK 21
- **Framework:** CodeGreen (Kotlin port of GenHTTP)
- **Engine:** CodeGreen internal engine (non-blocking, Netty)
- **Serialization:** kotlinx.serialization
- **Database:** PostgreSQL via JDBC + HikariCP (queried directly, as `genhttp-11` uses Npgsql)
- **Build:** Gradle composite build — the app pulls CodeGreen in via `includeBuild`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameters `a` + `b` |
| `/baseline11` | POST | Sums `a` + `b` + a value read from the body |
| `/baseline2` | GET | Sums query parameters `a` + `b` |
| `/json/{count}` | GET | Processes the first `count` dataset items; `?m=` scales each total (default 1) |
| `/upload` | POST | Drains the request body, returns the byte count |
| `/async-db` | GET | `price BETWEEN min AND max` range query (sequential scan) |
| `/crud/items` | GET | Paged listing by category |
| `/crud/items/{id}` | GET | Cached single-item read (`X-Cache: HIT\|MISS`) |
| `/crud/items` | POST | Upsert, returns `201 Created` |
| `/crud/items/{id}` | PUT | Partial update, `404` when the id is unknown |

## Profiles

Declared in `meta.json`: `baseline`, `pipelined`, `limited-conn`, `json`, `upload`,
`async-db`, `crud`, `api-4`, `api-16`.

**Not implemented** — these depend on modules the port does not provide yet, so they are
left out of `meta.json`:

- `json-comp` — response compression (Compression module)
- `json-tls`, `baseline-h2`, `static-h2`, `baseline-h2c`, `json-h2c` — TLS / HTTP-2
- `static` — static file serving (Files module)
- `echo-ws` — WebSockets module
- `fortunes` — HTML templating
- HTTP/3 and gRPC profiles

## Notes

- The single-item CRUD read uses an in-process 200 ms TTL cache-aside (mirrors the C# entry's `MemoryCache`).
- `DATABASE_URL`, `DATASET_PATH` and `DATABASE_MAX_CONN` follow the standard HttpArena contract.
  Without `DATABASE_URL`, the database-backed endpoints degrade gracefully (empty results / `404`).
- The Docker build clones CodeGreen from its `port` branch and builds it as a composite build,
  so that branch must contain the webservice stack (currently in PR — `dotnet-web-stack/CodeGreen`).

## Build & run locally

The app consumes CodeGreen as a composite build. Point at a local checkout:

```sh
./gradlew shadowJar -PcodegreenDir=/path/to/CodeGreen
DATASET_PATH=../../data/dataset.json java -jar build/libs/fishcake.jar
```

In Docker the CodeGreen checkout is cloned to `./codegreen` automatically (see `Dockerfile`).
