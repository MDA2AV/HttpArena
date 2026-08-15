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
| `/upload` | POST | Reads the body and returns the byte count |

## Notes

- Routing and path parameters through URLRouter
- JSON serialized by vibe.data.json from a struct, so the field order is the struct order
- Compression through `HTTPServerSettings.useCompressionIfPossible`, vibe.d's own
  Accept-Encoding negotiation, so nothing is compressed unless the client asks
- One listener task per available core, all on the same port through `SO_REUSEPORT`,
  because each vibe.d event loop runs on a single thread
- The core count comes from the cgroup v2 quota, then from the CPU affinity mask
- TLS is left out of the build (`vibe-stream:tls` in the `notls` configuration): the
  profiles here are all plaintext, and it keeps OpenSSL out of the runtime image
- `maxRequestSize` is raised to 64 MB, the default of 2 MB rejects the 20 MB upload
- The dataset is read once before the workers start, and a missing file is not fatal:
  `/json` then answers with an empty list
