# agensio

[agensio](https://github.com/YiannisBourkelis/agensio) is a static-file and reverse-proxy
server written in C++ on standalone Asio, with its own HTTP/1.1, HTTP/2 and HTTP/3 (QUIC)
layers over OpenSSL for TLS. One event loop per worker, each with its own `SO_REUSEPORT`
acceptor (and its own UDP socket for QUIC); a connection never leaves its worker. Files are served from a cache whose per-worker index is lock-free
over one shared store, with the response header blocks prebuilt at insert and the
pre-compressed `.br` / `.gz` twins of a file cached beside it and chosen by `Accept-Encoding`.

## Stack

- **Language:** C++
- **Engine:** agensio, built from the tag the Dockerfile pins with `-march=native` and
  `-DAGENSIO_HTTPARENA=ON`, the build option that compiles the benchmark handler
- **TLS:** OpenSSL 3 (Debian trixie), TLS 1.2 and 1.3, tickets on
- **Build:** Debian trixie, runtime `debian:trixie-slim`

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 | baseline, pipelined, limited-conn |
| 8081 | HTTP/1.1 + TLS (ALPN offers `http/1.1` only) | json-tls, static-tls |
| 8082 | HTTP/2 cleartext (prior knowledge) + HTTP/1.1 | baseline-h2c, json-h2c |
| 8443 | h2 + HTTP/1.1 over TLS (tcp), h3 over QUIC (udp); the site listens on `[::]:8443`, dual-stack | baseline-h2, static-h2, baseline-h3, static-h3 |

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11`, `/baseline2` | GET, POST | The sum of the query arguments' values, plus the body's number on a POST |
| `/json/{count}?m={multiplier}` | GET | The first `count` dataset items with `total = price * quantity * m`, rendered from prefixes prepared at load |
| `/pipeline` | GET | `ok`, text/plain |
| `/static/{filename}` | GET | Served from the mounted `/data/static` through the cache; a `.br` or `.gz` twin goes out to a client that takes it |

## Notes

- One process with the four listeners: `protocols` is set per site, so 8081 stays HTTP/1.1
  while 8443 offers h2 and h3. `workers = 0` is one worker per CPU of the container's cpuset.
- The handler (`src/handlers/httparena.cpp`) is a module loaded by the server, compiled in
  by a CMake option that release builds leave off; it never touches the static path.
- HTTP/3 (QUIC) on 8443/udp beside h2 on 8443/tcp: agensio's own transport over OpenSSL 3.5's QUIC TLS API (`baseline-h3`, `static-h3`).
- The cache revalidates a file and its twins at most once a second (`stat`, mtime and size),
  so a replaced file is served fresh within a second.
