# araara-standard — HttpArena standard entry

This entry installs HCS **0.18.0 through opam** and compiles the bundled
`server/arena.ml` benchmark application. It uses the same release and source
as the tuned `araara` entry, with `HCS_ARENA_MODE=standard`.

HCS defaults are kept except for the harness's ports, protocols and certificates,
`SO_REUSEPORT` so each domain can bind the listeners, and the legacy plaintext
upload size allowance. The application already supports standard mode; the
obsolete `standard-mode.patch` is no longer used.

In the HCS source repository, export this template with:

```sh
arena/prepare-submission.sh /path/to/HttpArena/frameworks
```

In the resulting HttpArena checkout:

```sh
docker build -t httparena-araara-standard frameworks/araara-standard
./scripts/validate.sh araara-standard
./scripts/benchmark.sh araara-standard
```

The build accepts `--build-arg HCS_VERSION=...` for another published release.
Packages come from the public araara opam repository. The old `hcs.0.16.1`
pin was absent from that index.

Listeners are 8080 (HTTP/1.1, h2c upgrade and WebSocket), 8443 (HTTP/2 over TLS),
8081 (HTTP/1.1 over TLS), and 8082 (HTTP/2 prior-knowledge).
`POST /echo` on TLS port 8081 returns the exact decoded bytes with status 200
and `application/octet-stream`; it supports empty, binary and chunked bodies.
The entry subscribes to `8gbit`, the current name of the echo benchmark.
See `meta.json` for the complete subscriptions.

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
