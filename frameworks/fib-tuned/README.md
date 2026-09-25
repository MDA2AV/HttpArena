# fib-tuned

The [`fib`](../fib) entry with one thing changed: response compression. Listeners, routes,
default fib configuration, static files and TLS are the same as there; see its README.

## Stack

- **Language:** Go 1.27 (fib's own `go.mod` requires it)
- **Framework:** fib `http`, `http3`, `tls` and `middleware` packages
- **Compression:** `andybalholm/brotli`, `klauspost/compress` (zstd, gzip, deflate)
- **Build:** `golang:1.27-alpine`, static binary on `scratch`

## Why tuned

fib's own `middleware/compress` codes gzip and deflate only. This entry replaces it with a
compression middleware written here ([`compress.go`](compress.go)), which the standard rules
do not allow - compression there has to be the framework's own - so the entry is `mode: tuned`.

## The middleware

It is built the way fib's `compress` is: a `middleware.Middleware` that registers one
`Context.OnResponse` hook and codes the whole body there, wrapped around `/json` and
`/async-db` with `middleware.Chain`. `/static` stays outside it, as in `fib`: its compressed
variants are already on disk, and a hook that sees the response whole would keep files off
`sendfile` on HTTP/1.

- **Codings:** `br`, `zstd`, `gzip`, `deflate`. The one `Accept-Encoding` gives the highest q
  wins; `*` stands for any not named; `q=0` refuses.
- **Between equal q values** (`gzip, br`, which is what `json-comp` sends) the server picks
  gzip, then zstd, brotli and deflate (`CompressConfig.Prefer`). On the 25/40/50-item bodies of
  that profile, 6.4 KB on average, measured on linux/arm64:

  | coding | average body | CPU per body |
  |---|---|---|
  | gzip 6 (klauspost) | 1254 B | 17 us |
  | zstd default | 1288 B | 14 us |
  | brotli 4 | 1225 B | 69 us |
  | brotli 5 | 1130 B | 66 us |
  | brotli 11 | 963 B | 5.1 ms |

  The profile scores throughput times the square of the smallest bytes-per-response over the
  entry's own, so brotli 5 would need to lose less than about a fifth of the rate to come out
  ahead, against four times the CPU of gzip. Brotli below quality 5 is no smaller than gzip at
  all. A client that prefers brotli by q value (`br;q=1, gzip;q=0.8`) gets brotli at quality 5.
- Levels: brotli 5, zstd default, gzip and deflate 6. Bodies under 256 bytes are left alone,
  a coded body that is no shorter is sent as it was, and every response that could have been
  coded carries `Vary: Accept-Encoding`.
- Writers are recycled through `sync.Pool`, and the coded body is copied out of a pooled buffer
  at its exact length; one zstd encoder serves every request through `EncodeAll`.
