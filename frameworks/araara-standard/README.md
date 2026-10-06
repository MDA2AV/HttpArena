# araara-standard

Builds the bundled HttpArena application against opam-installed HCS 0.18.0
and simdjsont 0.5.0, using standard OCaml 5.4 on Debian 12.

```sh
docker build -t httparena-araara-standard frameworks/araara-standard
./scripts/validate.sh araara-standard
```

`meta.json` lists the 14 supported profiles. Listeners: HTTP/1.1 and WebSocket
on 8080, HTTP/2 TLS on 8443, HTTP/1.1 TLS on 8081, and h2c on 8082. The harness
mounts `/data/dataset.json`, `/data/static` and `/certs`; Postgres uses
`DATABASE_URL` and `DATABASE_MAX_CONN`.

Handlers use HCS routing, query/body APIs, response constructors,
`Plug.Compress`, and `Plug.Static.server`. JSON uses per-request simdjsont
serialization, following [araara's JSON documentation](https://araara.ml/docs/simdjsont).
The static mount adapter removes a redundant `Content-Length`: HCS 0.18.0's
server adds its own, and duplicates break HTTP/2 responses.

Standard mode retains HCS defaults with the listener settings and
`SO_REUSEPORT` needed to bind across domains.

Completeness declares routing, middleware and request as true, and response
as false because the application invokes JSON serialization before
`Hcs.Response.json`. These values remain subject to maintainer review.
