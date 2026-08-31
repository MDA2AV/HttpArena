# vibed

vibe.d on its own fiber based event loop, default configuration.

## Stack

- **Language:** D, compiled with LDC 1.40
- **Framework:** vibe.d 0.10 (vibe-http 1.5) with URLRouter
- **Build:** `debian:trixie-slim`, dub release build

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- Routing and path parameters through URLRouter
- JSON serialized by vibe.data.json from a struct, so the field order is the struct order
- Compression through `HTTPServerSettings.useCompressionIfPossible`, vibe.d's own
  Accept-Encoding negotiation, so nothing is compressed unless the client asks
- One listener task per available core, all on the same port through `SO_REUSEPORT`,
  because each vibe.d event loop runs on a single thread
- The core count comes from the cgroup v2 quota, then from the CPU affinity mask
- TLS comes from `vibe-stream:tls` in its `openssl` configuration, so the handshake
  is OpenSSL's and not a second stack bolted on. The build image needs `libssl-dev`;
  `libssl3t64` is already in `debian:trixie-slim`, so the runtime image is unchanged
- The json-tls listener is created inside the same `runWorkerTaskDist` body as the
  plaintext one, so port 8081 gets a listener per core through `SO_REUSEPORT` too.
  Binding it once outside the dist task would have pinned every TLS connection to
  one event loop and measured a single thread
- ALPN answers `http/1.1` and nothing else: 8081 is the HTTP/1.1 port and h2 lives
  on 8443, so an h2-capable client must never be offered the upgrade here
- A missing `/certs` is not fatal — the TLS listener just stays down. `validate.sh`
  mounts the directory only for entries subscribed to a TLS test, so the plaintext
  profiles have to start without it
- `maxRequestSize` is raised to 64 MB, the default of 2 MB rejects the 20 MB upload
- The dataset is read once before the workers start, and a missing file is not fatal:
  `/json` then answers with an empty list
