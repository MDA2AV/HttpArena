# fib-tuned

The [`fib`](../fib) entry with three things changed: response compression, JSON encoding, and
the garbage collector's target. Listeners, routes, static files, TLS and fib's configuration are
the same as there; see its README.

## Stack

- **Language:** Go 1.27 (fib's own `go.mod` requires it)
- **Framework:** fib `http`, `http3`, `grpc`, `tls` and `middleware` packages
- **Compression:** `andybalholm/brotli`, `klauspost/compress` (zstd, gzip, deflate)
- **JSON:** `bytedance/sonic`, as fiber-tuned uses, for the `/json` and `/async-db` responses,
  which answer through `Context.JSON` as in `fib`, with sonic set as fib's `JSONEncoder`:
  json-tls served 1.06M requests a second with it against 747k through `encoding/json` on 64
  CPUs, with the same bytes out
- **Build:** `golang:1.27-alpine`, static binary on `scratch`

## Why tuned

fib's own `middleware/compress` codes gzip and deflate only. This entry replaces it with a
compression middleware written here ([`compress.go`](compress.go)), which the standard rules
do not allow - compression there has to be the framework's own - so the entry is `mode: tuned`.

It also sets **`GOGC=200`**, in the Dockerfile. Requests make garbage far faster than the server
keeps anything live, so a higher target trades memory for the collector's share of the CPUs. On
64 CPUs, in 32 prefork children with a heap each, against GOGC=100 and 400:

| Profile | GOGC=100 | GOGC=200 | GOGC=400 |
| --- | --- | --- | --- |
| json-tls | 1.42M req/s, 511 MB | 1.56M req/s, 688 MB | 1.64M req/s, 1.0 GB |
| json-comp, 16384 connections | 559k req/s, 0.9 GB | 586k req/s, 2.5 GB | 600k req/s, 6.7 GB |
| async | 2.05M req/s, 1.4 GB | 2.01M req/s, 2.1 GB | 1.95M req/s, 2.7 GB |
| baseline | 3.63M req/s, 362 MB | 3.64M req/s, 463 MB | 3.63M req/s, 809 MB |

200 keeps most of 400's throughput where the collector is what limits it, at about half the
memory.

fib's configuration is its defaults, and the entry is served through fib's `prefork` package, as
in `fib`: a child process for every two CPUs, each with its own heap, and so its own `GOGC=200`
target. fib's defaults recycle each request's `*http.Request`, `Header`, `URL` and `*Context`
once its response is finished; no handler here keeps any of them past its response.

## The middleware

It is built the way fib's `compress` is: a `middleware.Middleware` that registers one
`Context.OnResponse` hook and codes the whole body there, wrapped around `/json` and
`/async-db` with `Router.With`. `/static` stays outside it, as in `fib`: its compressed
variants are already on disk.

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
