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
`DATABASE_URL` and `DATABASE_MAX_CONN`. The async-db handler uses Caqti 3.0.0’s
nonblocking PostgreSQL driver with Eio pools and a prepared, parameterized query.
Worker count follows CPU affinity; their pools share the supplied connection
budget. An unavailable database returns the required empty JSON result.

Handlers use HCS routing, query/body APIs, response constructors,
`Plug.Compress`, and `Plug.Static.server`. JSON uses per-request simdjsont
serialization, following [araara's JSON documentation](https://araara.ml/docs/simdjsont).
The static mount adapter removes a redundant `Content-Length`: HCS 0.18.0's
server adds its own, and duplicates break HTTP/2 responses.

Tuned mode raises connection capacity to 200,000 and sets
`HCS_H2_MAX_STREAMS=64`.

Completeness declares routing, middleware and request as true, and response
as false because the application invokes JSON serialization before
`Hcs.Response.json`. These values remain subject to maintainer review.
