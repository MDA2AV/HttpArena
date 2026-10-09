# vanilla-veb_like

[vanilla](https://github.com/enghitalo/vanilla), a multi-threaded HTTP/1.1
server written in [V](https://vlang.io), with its declarative router,
[`http1_1.veb_like`](https://github.com/enghitalo/vanilla/tree/main/http1_1/veb_like).
`vanilla-router` is the same app with the explicit router.

## Stack

- **Language:** V 0.5.2 (master `5516000`, built from source with a pinned bootstrap)
- **Framework:** vanilla `fb4c7e7`: epoll workers, one per CPU of the cpuset, `SO_REUSEPORT`
- **Router:** `http1_1.veb_like`
- **Build:** `-prod -gc none`, vanilla's production build

## Routing

Routes are attributes on the methods of `App` (`:8080`) and `TlsApp` (`:8081`):

```v
@['GET /json/:count']
fn (app &App) json(req HttpRequest, p &Params, mut out []u8, _ int, worker_state voidptr, mut _ core.EventLoop) core.Step {
	mut w := unsafe { &Worker(worker_state) }
	return json_items(mut w, req, p.get('count'), mut out)
}
```

`veb_like.new` reads the attributes at startup and compiles them into a segment trie,
failing on a malformed or conflicting route. Per request, the router parses the request,
walks the trie, fills the route's `:params` with views of the request buffer and calls the
method directly. It answers 404, 405 with `Allow`, and 501 itself, and serves HEAD from the
GET route. `main.v` holds the two apps. `app.v` holds what each route does, and is the same
file in `vanilla-router`.

## Endpoints

| Endpoint | Method | Port | Profile |
|----------|--------|------|---------|
| `/pipeline` | GET | 8080 | pipelined |
| `/baseline11?a=&b=` | GET, POST | 8080 | baseline, limited-conn, latency-* |
| `/json/{count}?m=N` | GET | 8080, 8081 | json-comp, json-tls |
| `/async-db?min=&max=&limit=` | GET | 8080 | async-db |
| `/fortunes` | GET | 8080 | fortunes |
| `/delay/{ms}` | GET | 8080 | async |
| `/static/{file}` | GET, HEAD | 8080, 8081 | static-tls |
| `/echo` | POST | 8080, 8081 | 8gbit |

## Notes

- Handlers append the raw response into a buffer the server owns, and return `.done`,
  `.suspend` (the response comes later, from a callback) or `.close`. A request whose
  `Connection` header lists `close` gets its response and then the connection closes.
- `/json` is serialized per request from the dataset's fields, and gzip-compressed per
  request with libdeflate when `Accept-Encoding` accepts gzip. Nothing is cached. Level 1:
  on these 4-8 KB bodies it is 2.5 times faster than level 6 for about 15% more bytes.
- `async-db` and `fortunes` park the request on vanilla's async Postgres driver,
  `pg_async`: each worker has its own pool, pipelined, sized from `DATABASE_MAX_CONN`. The
  worker serves other connections until the reply arrives.
- `fortunes` adds the runtime row, sorts and renders the page by hand per request, every
  message HTML-escaped.
- `/delay/{ms}` parks the request on a one-shot timerfd, taken from a per-worker free-list.
- `/static` goes through vanilla's `static_assets`: it picks the `.br`/`.gz` sibling on disk
  per `Accept-Encoding`, re-checks each file against the disk (one `stat` per 100 ms), and
  sends bodies of 16 KiB or more with `sendfile(2)`, over kTLS on `:8081`.
- `:8081` is TLS 1.3 with ALPN `http/1.1` through Mbed TLS 4, built from source with a
  patch that caches the parsed RSA signing key per thread.
- Built with `-gc none`, so a per-request allocation would never be freed. Each worker reuses its
  buffers instead: after warm-up, every plaintext route makes 0 allocation calls per request,
  except `fortunes`, where libc `qsort` takes a scratch buffer and frees it.
- `mode: tuned` because of the hand-written JSON and HTML, libdeflate and `-gc none`.
