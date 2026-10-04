# fib-tuned

The [`fib`](../fib) entry with two things changed: response compression, and the
configuration its TCP servers run with. Listeners, routes, static files and TLS are the same as
there; see its README.

## Stack

- **Language:** Go 1.27 (fib's own `go.mod` requires it)
- **Framework:** fib `http`, `http3`, `tls` and `middleware` packages
- **Compression:** `andybalholm/brotli`, `klauspost/compress` (zstd, gzip, deflate)
- **Build:** `golang:1.27-alpine`, static binary on `scratch`

## Why tuned

fib's own `middleware/compress` codes gzip and deflate only. This entry replaces it with a
compression middleware written here ([`compress.go`](compress.go)), which the standard rules
do not allow - compression there has to be the framework's own - so the entry is `mode: tuned`.

It also runs with the fib settings the standard rules keep at their defaults:

- **Each event loop accepting for itself.** fib's default spreads an engine over one loop per
  CPU (`fib.Config.IOPollers`); every TCP engine here also sets `fib.Config.ReusePort`, which has
  each loop listen on the engine's addresses with a socket of its own, bound with `SO_REUSEPORT`,
  and accept its connections itself. The UDP engine (HTTP/3) keeps the defaults: its peers share
  one socket, which stays on the engine's own loop. HTTP/1 requests still run on fib's worker
  pool, as they do by default, so a handler that blocks holds up only its own connection.
- **Recycled requests.** `ReuseRequests`, `ReuseHeaders`, `ReuseURLs` and `ReuseContexts`
  recycle the `*http.Request`, its `Header` and `URL`, and the `*Context` once a response is
  finished. No handler keeps any of them past its response.
- **`GOMAXPROCS` at twice the CPUs**, which fib's guide gives for loops that block in
  `epoll_wait`: one loop per CPU can hold every P while it waits, and the workers and the
  goroutines the handlers start (the `/async-db` queries, the `/delay` timers) then wait for
  one. On six CPUs it took async-db from 38k to 46k req/s and baseline from 895k to 940k.
- **`GOGC=400`**, set in the Dockerfile. Requests make garbage far faster than the server keeps
  anything live: at the default the collector ran 24 cycles a second on six CPUs at 874k req/s,
  and at 400 it ran 9 a second, with the heap under 130 MB, at 978k req/s.

On six CPUs of a local Docker VM, against the `fib` entry on the same fib build, these took
baseline from 745k to 980k req/s, limited-conn from 550k to 710k, pipelined from 3.55M to 7.5M,
async from 310k to 347k and json-comp, with the entry's own compression, from 91k to 107k;
async-db stayed at 46k.

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
