# araara

Experimental tuned HttpArena entry for araara, an OCaml 5 web stack built on
HCS and Eio.

The benchmark server source is `arena/server/arena.ml` in the HCS repository.
This Dockerfile clones the HCS release selected by `HCS_REF` and builds that
server, so the framework directory only contains submission metadata and build
instructions.

Listeners:

| Port | Protocol | Profiles |
|------|----------|----------|
| 8080 | HTTP/1.1 + h2c upgrade + WebSocket | baseline, pipelined, limited-conn, json, json-comp, upload, static, async-db, crud, api-*, echo-ws |
| 8443 | TLS, ALPN `h2,http/1.1` | baseline-h2, static-h2 |
| 8081 | TLS, ALPN `http/1.1` | json-tls |
| 8082 | cleartext HTTP/2 prior-knowledge | baseline-h2c, json-h2c |

Not implemented: HTTP/3 / QUIC, gRPC, gateway-64, and production-stack.
