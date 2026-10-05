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

## Implementation rules

Both modes register handlers through `Hcs.Router` and `Hcs.Endpoint`, read
parameters with `Hcs.Request` and `Hcs.Router`, and build responses with
`Hcs.Response`. JSON is decoded and serialized with published **simdjsont
0.5.0**, araara's [documented JSON library](https://araara.ml/docs/simdjsont).
HCS deliberately leaves JSON codec selection to applications. Every JSON
response is serialized per request; no hand-built JSON or cached response bytes
are used. `Plug.Compress.create ()` handles JSON and static compression in the
normal route pipeline, with its default settings.

Static routes use the released **`Hcs.Plug.Static.server`** with an Eio directory
capability rooted at `/data/static`. The adapter removes the `/static` mount prefix using the router's wildcard
parameter and strips the redundant `Content-Length` emitted by `Plug.Static`:
HCS 0.18.0's server adds its own length, and duplicates break HTTP/2 framing.
This is a compatibility correction; file bytes are unchanged. HCS owns file access,
path validation and MIME selection. The application has no static cache;
replacing, adding or deleting a file takes effect on the next request.
`/pipeline` also constructs its response for each request.

Completeness is declared explicitly: routing, middleware and request are
`true`; response is conservatively `false` because the application invokes the
JSON serializer before passing bytes to `Hcs.Response.json`. HCS supplies form
parsing and buffered/streaming body access, but does not serialize JSON values
as part of its response constructor. These declarations are proposed for
maintainer review under the [completeness rules](https://www.http-arena.com/#doc=scoring/completeness).

The additional regression requires curl with HTTP/2 support and a **writable
host copy of the fixtures mounted into an isolated test container**:

```sh
python3 test-compliance.py https://localhost:8443 \
  --static-dir /path/to/mounted/data/static \
  --dataset /path/to/mounted/data/dataset.json
```

It compares all static assets byte-for-byte, atomically replaces a file with
one of the same size and timestamp, checks gzip and identity responses,
restores the file, checks additions/deletions and traversal rejection, and
checks JSON schema, parameter variation, URI decoding and content negotiation.
For JSON escaping coverage, repeat with a dataset containing quotes,
backslashes, control characters and Unicode, mounted before starting the server.

## Validation of this revision

Against HttpArena `5b111b8889fee61076f1d7dd14fdb3dfd12c8492`, both entries passed:

- The full upstream suite: **84 passed, 0 failed** per entry.
- Extra binary echo: **18 HTTPS + 18 plaintext** checks per entry.
- `test-compliance.py`: **74 passed** per entry, using a dataset with quotes,
  backslashes, control characters and Unicode as well as the live file tests.

Both standalone images and the local HCS arena image built with standard OCaml
5.4 and opam-installed HCS 0.18.0 and simdjsont 0.5.0. Yojson is not installed
or linked by the benchmark. The remote test host denies unlimited memlock, so
only `--ulimit memlock=-1:-1` was removed from a temporary validator copy;
no correctness assertions were changed or skipped. Eio used its POSIX fallback.
These are correctness checks, not leaderboard performance measurements.
