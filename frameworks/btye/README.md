# BT-YE

[BT-YE](https://github.com/kelbon/BT-YE) is a C++23 framework for HTTP/2 services: an actor (event loop) per
core, coroutines ([kelcoro](https://github.com/kelbon/kelcoro)), HTTP/2 by [hidi](https://github.com/kelbon/hidi),
and the server and client generated from an OpenAPI spec by [svarg](https://github.com/kelbon/svarg).

## Stack

- **Language:** C++23
- **Engine:** hidi
- **Build:** `ubuntu:24.04`, clang 20, `-O3 -march=native`; BT-YE's CMake fetches its dependencies with CPM

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8443 | h2 (TLS, ALPN) | baseline-h2, static-h2 |
| 8082 | h2c (prior knowledge) | baseline-h2c, json-h2c |

BT-YE speaks HTTP/2 only, so there is no HTTP/1.1 listener on 8080. One actor per CPU in the process affinity
mask; both listeners accept on one actor and hand the connections out to all of them.

## Endpoints

The API is described in [arena.yaml](arena.yaml); routing, parameter parsing, JSON parsing and serialization
are generated from it.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline2` | GET | Sum of the query parameters `a` and `b`, `text/plain` |
| `/json/{count}?m={m}` | GET | The first `count` dataset items with `total = price * quantity * m` |
| `/static/{filename}` | GET | Files of `/data/static`, the `.br` / `.gz` copy when the client accepts it |
