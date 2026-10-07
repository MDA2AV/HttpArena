# araara

Builds the bundled HttpArena application against opam-installed HCS 0.18.0
and simdjsont 0.5.0, using standard OCaml 5.4 on Debian 12 and Dune’s release profile.

```sh
docker build -t httparena-araara frameworks/araara
./scripts/validate.sh araara
```

`meta.json` lists the 14 supported profiles. Listeners: HTTP/1.1 and WebSocket
on 8080, HTTP/2 TLS on 8443, HTTP/1.1 TLS on 8081, and h2c on 8082. The harness
mounts `/data/dataset.json`, `/data/static` and `/certs`; Postgres uses
`DATABASE_URL` and `DATABASE_MAX_CONN`. Repodb 0.9.0 owns the shared connection
pool and prepared queries. Typed `Query`/`Expr` builders and `Repo.all_query`
bind the range and limit parameters. Its synchronous calls run through
`Eio_unix.run_in_systhread`; an Eio semaphore bounds offloaded work by the
connection budget, so waiting requests suspend their fibers. An unavailable
database returns the required empty JSON result. Worker count follows CPU affinity.

Both entries reuse the immutable tags codec and retain decoded ratings as pairs,
avoiding codec construction per database row and temporary pairs during encoding.
Tuned additionally reads HCS-decoded query parameters once on routes needing
multiple integers, avoiding repeated query parsing without a custom URI parser.
GC settings, database work, per-request serialization, and compression are unchanged.

Handlers use HCS routing, request body/query APIs, response constructors, and
`Plug.Compress` for JSON. JSON uses per-request simdjsont serialization,
following [araara's JSON documentation](https://araara.ml/docs/simdjsont).
The tuned static path selects disk-backed `.br` / `.gz` sidecars according to
`Accept-Encoding` and reads the chosen file per request, so file replacements are
reflected by the next response.

Tuned mode raises connection capacity to 200,000, sets `HCS_H2_MAX_STREAMS=64`,
serves pre-compressed static sidecars, and trims a few hot-route allocations
while keeping the same HCS router/request/response surface.

Completeness declares routing, middleware and request as true, and response
as false because the application invokes JSON serialization before
`Hcs.Response.json`. These values remain subject to maintainer review.
