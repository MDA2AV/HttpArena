# libreactorng

[libreactorng](https://github.com/fredrikwidlund/libreactorng) — Fredrik Widlund's io_uring-native event framework, the successor to the epoll-based libreactor that held top placements on TechEmpower plaintext/JSON for years.

## Stack

- **Language:** C
- **Engine:** io_uring (Linux)
- **Dependencies:** libreactor (built from source), liburing, libssl
- **Build:** `ubuntu:24.04` → `ubuntu:24.04`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (text/plain) |
| `/baseline11` | GET | Sum of integer query args |
| `/baseline11` | POST | Sum of query args + integer body |
| `/baseline2` | GET | Same as baseline11 GET (parity with H/2 profile) |

## Notes

- Single `on_request` callback dispatches on `session->request.target`; libreactor parses method / target / body for us.
- One reactor per logical CPU in the container's affinity mask, forked up front. Each worker creates its own `SO_REUSEPORT` socket so the kernel distributes incoming accepts.
- Requires `--security-opt seccomp=unconfined` (default Docker seccomp blocks several io_uring ops). The harness adds this automatically for frameworks declaring `"engine": "io_uring"` in `meta.json`.
- Response bodies computed on the stack are safe — `http_write_response` copies through `stream_allocate` before returning control to the event loop.

## Known limitation

libreactor's HTTP server keeps connections open unconditionally — it ignores the `Connection` request header and the only teardown API (`server_disconnect` → `stream_close`) is abortive. That makes the TCP-fragmentation validation checks in `scripts/validate.sh` (which send `Connection: close` and then `recv` until EOF) time out waiting for a close that never comes. Plain `curl`-driven checks are fine because curl uses `Content-Length`. Fixing this cleanly needs a write-completion hook in libreactor's `stream_t`, which isn't exposed in the public API.
