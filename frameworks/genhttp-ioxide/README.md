# genhttp-ioxide

[GenHTTP](https://github.com/Kaliumhexacyanoferrat/GenHTTP) running on
[ioxide](https://github.com/MDA2AV/ioxide), an io_uring, thread-per-core runtime with one reactor per core.

GenHTTP has pluggable server engines, and `GenHTTP.Engine.Ioxide` is the one built on ioxide. The
application is ordinary GenHTTP code: layouts, webservices, the static asset handler, compression
and websockets, all the same as on the default engine. Under that code, ioxide handles the
connections, HTTP/1.1, HTTP/2, HTTP/3 and TLS. Compared with the [`genhttp`](../genhttp) entry, only
the engine changes.

## Implementation

| Route | Handler |
|---|---|
| `/baseline11`, `/baseline2` | `Baseline` webservice: sums the query values and the request body |
| `/pipeline` | A static `ok` resource |
| `/json/{count}` | `Json` webservice, with Brotli compression on this route only |
| `/static/...` | `Assets`, which serves the pre-compressed `.br` files itself |
| `/echo` | `Echo` webservice: returns the request body unchanged |
| `/delay` | A plain `IHandler` that waits on an ioxide ring timer (`ioxide.timer`) |
| `/async-db`, `/crud/items` | Webservices on Postgres via `ioxide.pg`, a ring-native pool for each reactor |
| `/ws` | GenHTTP websocket echo, with frames of up to 64 KiB |
| `/spec`, `/spec/headers` | The [compliance](https://http-arena.com/docs/test-profiles/compliance/) route |

`ioxide.pg` opens a Postgres pool on each reactor through the engine's `onReactorStart` hook.
Handlers get that reactor's pool from `IoxideReactor.Current`, so the engine itself does not
depend on Postgres. The database routes are mounted only when `DATABASE_URL` is set. The TLS
listeners come up only when a certificate pair is mounted.

TLS is terminated by the engine in OpenSSL, with kernel TLS (kTLS) for sending. kTLS pins the
minimum version to TLS 1.3 and needs the Linux `tls` module on the host
(`/proc/sys/net/ipv4/tcp_available_ulp` should list `tls`).

## Build

The entry targets .NET 11. The Dockerfile builds GenHTTP from source at a pinned commit
(`GENHTTP_COMMIT`), so the entry can run engine changes before they are released. The `ioxide.pg`
and `ioxide.timer` packages must match the ioxide version that this GenHTTP commit pins, so
update them together.
