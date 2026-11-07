# fit

[fit](https://github.com/lesismal/fit), a reverse proxy, load balancer, TLS terminator, static file
server and API gateway built on [fib](https://github.com/lesismal/fib), in the same space as nginx,
Caddy and Traefik. It enters as infrastructure, as they do: the dynamic endpoints are answered by a
handler module compiled into fit, and the static files by fit's own `static` handler.

## Stack

- **Language:** Go 1.27.3
- **Server:** fit v1.0.0 on fib v1.7.2
- **Module:** [`httparena`](httparena/httparena.go), registered as fit's own modules are
  (`module.Register` under `http.handlers`), compiled in by [`main.go`](main.go), which is what
  `fit build -with` generates: fit's command line and `modules/standard`, without the providers
  and the roles beside the gateway, which the config names none of
- **Config:** [`fit.conf`](fit.conf), fit's own .conf format
- **Build:** `golang:1.27.3-alpine`, static binary on `scratch`

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 | baseline, pipelined, limited-conn |
| 8081 | HTTP/1.1 over TLS, ALPN `http/1.1` | json-tls, static-tls |
| 8082 | h2c, prior knowledge | baseline-h2c, json-h2c |
| 8443 | h2 (and HTTP/1.1) over TLS, h3 over QUIC on 8443/udp | baseline-h2, static-h2, baseline-h3, static-h3 |

Every route is served on every listener (`site *`).

## Endpoints

| Endpoint | Method | Handler |
|----------|--------|---------|
| `/pipeline` | GET | `respond`, a fixed `ok` as `text/plain` |
| `/baseline11` | GET, POST | `httparena`: `a + b` from the query, plus the body on POST |
| `/baseline2` | GET | `httparena`, the same sum, for h2, h2c and h3 |
| `/json/{count}?m=N` | GET | `httparena_json`: the dataset's first `count` items with `total = price * quantity * m` |
| `/static/{file}` | GET | `static`, from `/data/static` |

## Notes

- **The module** answers before `ServeHTTP` returns, on fib's workers, and does nothing on a
  request that could block: the dataset is read from `/data/dataset.json` once, when the config is
  loaded (a missing one leaves `/json` with an empty list, and the other profiles still run), and
  each `/json` response is built and serialized per request through `Context.JSON`
  (encoding/json). Query parameters are read with `Context.Query`, without building `URL.Query`'s
  map, and a POST body arrives whole, Content-Length or chunked, before the handler runs, read in
  place through `Context.Body`.
- **Static files** go through fit's `static` handler with `precompressed br gzip`: files of up to
  1 MiB are kept in memory (64 MiB in all), what it knows of a path is revalidated against the
  disk once a second (`check_interval`), so a replaced file is served within a second, and the
  `.br` or `.gz` twin on disk is chosen off `Accept-Encoding`. Content types come from the file
  names.
- **Protocols** are fit's, which are fib's: HTTP/1.1, HTTP/2 and HTTP/3 over fib's own QUIC, TLS
  on Go's crypto/tls with certificates from `/certs`. fit tells HTTP/1.1 from h2c by what a client
  sends first; 8080 and 8082 each serve one, so that each profile measures its protocol.
- **Configuration** is fit's defaults, fib's engine settings among them, but for the logs, which
  are at `warn`, and `auto_https`, which is off: the listeners are written out, so nothing is
  obtained with ACME and no redirect listener is opened. fit runs as one process.
- fit is new work: 1.0 is out and its external security review is still to come.
