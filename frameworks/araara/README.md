# araara — HttpArena tuned entry

This entry installs HCS **0.18.0 through opam**, then compiles the bundled
`server/arena.ml` benchmark application against that release. The application
source is included so endpoint changes can be reviewed and maintained here.
The public package repository is
`git+https://tangled.org/gdiazlo.tngl.sh/repo`.

In the HCS source repository, export this template with:

```sh
arena/prepare-submission.sh /path/to/HttpArena/frameworks
```

In the resulting HttpArena checkout:

```sh
docker build -t httparena-araara frameworks/araara
./scripts/validate.sh araara
./scripts/benchmark.sh araara
```

The Docker build accepts `--build-arg HCS_VERSION=...` for another published
release. The old `hcs.0.16.1` pin was not available in the opam repository.

| Port | Protocol | Workloads |
|------|----------|-----------|
| 8080 | HTTP/1.1 + h2c upgrade + WebSocket | baseline, latency, pipelined, limited-conn, json-comp, async-db, echo-ws |
| 8443 | TLS, ALPN `h2,http/1.1` | baseline-h2, static-h2 |
| 8081 | TLS, ALPN `http/1.1` | json-tls, 8gbit |
| 8082 | cleartext HTTP/2 prior-knowledge | baseline-h2c, json-h2c |

`POST /echo` returns the body unchanged as `application/octet-stream`, including
binary, empty and chunked requests. `8gbit` is the current name of the former
`echo-10k` profile. The runner mounts `/data/dataset.json`, `/data/static/`,
and `/certs/server.{crt,key}`. Postgres uses `DATABASE_URL`.

This is the experimental tuned entry. `meta.json` lists its exact subscriptions.
The benchmark app has no HTTP/3, gRPC, or multi-service gateway endpoints.

## Endpoint coverage

Both araara entries implement the same endpoints:

| Profiles | Endpoint | Listener |
|----------|----------|----------|
| baseline, latency-1m, latency-10k, limited-conn | GET/POST `/baseline11?a=...&b=...` | HTTP/1.1 :8080 |
| pipelined | GET `/pipeline` | HTTP/1.1 :8080 |
| json-comp / json-tls / json-h2c | GET `/json/{count}?m=...` | :8080 / TLS :8081 / h2c :8082 |
| 8gbit | POST `/echo` | HTTP/1.1 over TLS :8081 |
| async-db | GET `/async-db?min=...&max=...&limit=...` | HTTP/1.1 :8080 |
| baseline-h2 / baseline-h2c | GET `/baseline2?a=...&b=...` | TLS :8443 / h2c :8082 |
| static-h2 | GET `/static/{file}` | HTTP/2 over TLS :8443 |
| echo-ws | WebSocket upgrade and text/binary echo at `/ws` | :8080 |

Run `scripts/validate.sh` for this entry from the HttpArena root to check every
subscribed profile. For extra echo coverage against a running container, run
`python3 test-echo.py https://localhost:8081` from this directory. It checks
random binary bodies, empty bodies, Content-Length and chunked framing, sizes
up to 1 MiB (including both sides of the old 256 KiB discard threshold), and
keep-alive reuse. The official `scripts/validate-ws.py` checks `/ws` and is
included in the full validator.
