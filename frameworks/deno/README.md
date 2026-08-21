# deno

Deno's own HTTP server, `Deno.serve`, with no framework on top.

## Stack

- **Language:** TypeScript
- **Runtime:** [Deno](https://github.com/denoland/deno) 2.9
- **Framework:** none, the whole app is one `fetch(Request): Response` handler
- **Build:** Single stage on `denoland/deno:2.9.5`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | Sums query parameter values, plus the body for POST |
| `/json/:count` | GET | Serializes a slice of the dataset, gzipped when the client accepts it |
| `/upload` | POST | Counts the bytes of the request body |

## Notes

- Multi-core scaling is `deno serve --parallel`, which runs one process per core and lets them
  share port 8080 through `SO_REUSEPORT`. Deno counts the cores itself and respects the cgroup
  quota, so this entry has no cluster code of its own.
- `Deno.serve` does not negotiate content encodings, so `/json/:count` reads `Accept-Encoding`
  per request and pipes the body through a `CompressionStream`. gzip and not brotli, because
  gzip is what that stream can do.
- The dataset is read once at startup. A missing file leaves an empty list, since the profiles
  other than json run without the mount.
- The path comes from slicing `request.url` rather than from `new URL()`: four routes need no
  matcher, and a URL object per request is not free.
