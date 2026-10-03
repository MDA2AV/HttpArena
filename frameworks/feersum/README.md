# feersum

Feersum on Perl 5.42: an event-driven, high-performance HTTP server engine based on EV (libev) with native TLS 1.3, HTTP/2, WebSocket, and PostgreSQL pipeline support.

## Stack

- **Language:** Perl (v5.42)
- **Engine / Server:** [Feersum](https://github.com/vividsnow/feersum) (1.507) with TLS 1.3 (picotls) and HTTP/2 (nghttp2)
- **Event Loop:** [EV](https://metacpan.org/pod/EV) (libev)
- **Routing:** [Router::Ragel](https://metacpan.org/pod/Router::Ragel) (Ragel state machine compiled to coderef dispatch)
- **WebSocket:** [EV::Websockets](https://metacpan.org/pod/EV::Websockets) (C/libwebsockets with raw socket adoption)
- **Database:** [EV::Pg](https://metacpan.org/pod/EV::Pg) (non-blocking pipelined PostgreSQL client)
- **Templates:** [Text::Stencil](https://metacpan.org/pod/Text::Stencil) (fast compiled HTML string templates)
- **JSON:** [JSON::XS](https://metacpan.org/pod/JSON::XS)
- **Compression:** [Gzip::Faster](https://metacpan.org/pod/Gzip::Faster) (level 1)
- **URL Decoding:** [URL::Encode::XS](https://metacpan.org/pod/URL::Encode::XS)
- **Memory Allocator:** jemalloc (`libjemalloc2`)
- **Concurrency:** Multi-process pre-fork (cgroup-aware CPU core detection) with `SO_REUSEPORT`

## Endpoints

| Endpoint | Method | Transport / Port | Description |
|----------|--------|------------------|-------------|
| `/pipeline` | GET | HTTP/1.1 (8080) | Returns `ok` (plain text) |
| `/baseline11` | GET/POST | HTTP/1.1 (8080) | Sums query parameter values, plus the body for POST |
| `/baseline2` | GET | HTTP/2 (8443) | Sums query parameter values over HTTP/2 |
| `/delay/:ms` | GET | HTTP/1.1 (8080) | Non-blocking async delay via EV timer, returns `$ms` |
| `/json/:count` | GET | HTTP/1.1 (8080, 8081) | Serializes dataset slice; gzip compressed when `Accept-Encoding: gzip` |
| `/echo` | POST | HTTP/1.1 (8080, 8081) | Returns request body bytes back verbatim (`application/octet-stream`) |
| `/static/:file` | GET | TLS 1.3 (8081, 8443) | Serves static assets from `/data/static/` with mapped Content-Type |
| `/async-db` | GET | HTTP/1.1 (8080) | Non-blocking price-range query over Postgres `items` table via `EV::Pg` |
| `/fortunes` | GET | HTTP/1.1 (8080) | Queries `fortune` table, appends runtime message, sorts, and renders HTML |
| `/ws` | GET (Upgrade) | WebSocket (8080) | Adopts socket and echoes text and binary frames via `EV::Websockets` |

## Subscribed Profiles

- `baseline`: HTTP/1.1 pipeline and query/body parsing
- `pipelined`: HTTP/1.1 pipelined plaintext requests
- `limited-conn`: High throughput under limited concurrency
- `async`: Non-blocking asynchronous timers (`/delay/:ms`)
- `latency-1m`: Latency under 1M req/s offered load
- `latency-10k`: Low-rate standing overhead efficiency
- `latency-500k-8cpu`: Throughput and queueing under 8-core CPU constraint
- `json-comp`: JSON serialization and dynamic gzip compression negotiation
- `json-tls`: JSON serialization over TLS 1.3 HTTP/1.1
- `8gbit`: 100 KB payload echo over TLS 1.3
- `static-tls`: 20 static files served over TLS 1.3 HTTP/1.1
- `baseline-h2`: Baseline query calculation over HTTP/2 with ALPN `h2`
- `static-h2`: Static asset serving over HTTP/2
- `async-db`: Non-blocking PostgreSQL query via `EV::Pg`
- `fortunes`: PostgreSQL query + HTML templating via `Text::Stencil`
- `echo-ws`: WebSocket echo throughput via `EV::Websockets`
- `echo-ws-pipeline`: 16x pipelined WebSocket echo
- `echo-ws-limited`: Short-lived WebSocket connections (10 msgs per connection)
