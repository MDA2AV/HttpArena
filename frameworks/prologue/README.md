# Prologue (Nim)

[Prologue](https://github.com/planety/prologue) is a powerful and flexible web framework written in Nim. Under the hood it uses [httpbeast](https://github.com/nicholasgasior/httpbeast) (via httpx) — a high-performance HTTP server that leverages epoll on Linux with multi-threaded request handling.

## Why Prologue?

- **Nim compiles to C** — native performance with a high-level, Python-like syntax
- **httpbeast backend** — uses epoll and SO_REUSEPORT for multi-core scaling
- **Zero-overhead routing** — trie-based router compiled at build time
- **First Nim framework in HttpArena** — brings a new language to the benchmarks

## Build

```bash
nim c -d:release -d:danger --opt:speed --threads:on -o:server server.nim
```

## Endpoints

All standard HttpArena endpoints are implemented: `/pipeline`, `/baseline11`, `/baseline2`, `/json`, `/compression`, `/upload`, `/db`, `/static/{filename}`.
