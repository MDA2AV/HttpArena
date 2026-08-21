# warp

Warp on WAI, default configuration.

## Stack

- **Language:** Haskell, GHC 9.6 (threaded runtime)
- **Framework:** Warp 3.3 with wai 3.2 and wai-extra 3.1
- **Build:** `debian:trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Streams the body and returns the byte count |

## Notes

- Routing is a case on the WAI `pathInfo`, warp has no router of its own
- JSON serialized with the aeson streaming encoding API, no intermediate `Value`
- Compression through the wai-extra Gzip middleware with its defaults
- The upload body is counted chunk by chunk, so a 20 MB body is never held whole
- One RTS capability per available core, read from the cgroup v2 quota so a
  cpu-limited container does not get the host core count
- GHC and the Haskell libraries come prebuilt from the Debian package set, which
  keeps the image build under a minute instead of compiling aeson from source
