# araara-standard

Builds the bundled HttpArena application against opam-installed HCS 0.18.0
and simdjsont 0.5.0, using standard OCaml 5.4 on Debian 12 and Dune’s release profile.

```sh
docker build -t httparena-araara-standard frameworks/araara-standard
./scripts/validate.sh araara-standard
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

Handlers use HCS routing, query/body APIs, response constructors,
`Plug.Compress`, and `Plug.Static.server`. JSON uses per-request simdjsont
serialization, following [araara's JSON documentation](https://araara.ml/docs/simdjsont).
The static mount adapter uses `Plug.Static.server` and, per HttpArena's standard
static-file rules, selects disk-backed `.br` / `.gz` sidecars when the client
advertises them. It also removes a redundant `Content-Length`: HCS 0.18.0's
server adds its own, and duplicates break HTTP/2 responses.

Standard mode retains HCS defaults with the listener settings and
`SO_REUSEPORT` needed to bind across domains.

Completeness declares routing, middleware and request as true, and response
as false because the application invokes JSON serialization before
`Hcs.Response.json`. These values remain subject to maintainer review.
