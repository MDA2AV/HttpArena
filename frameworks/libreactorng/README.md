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

## Connection: close

libreactor's HTTP server keeps connections open unconditionally and its only teardown primitive
(`stream_close`) is abortive - it closes before queued response bytes reach the socket. This entry
applies a small patch (`connection-close.patch`) adding `stream_close_on_drain()`, which defers the
close until the output buffer has fully drained. The server calls it when a request carries
`Connection: close`, so the TCP-fragmentation validation (which sends `Connection: close` and reads
to EOF) sees a clean close after the full response.
