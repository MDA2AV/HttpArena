# blitz ⚡

A Zig micro web framework built for raw speed. Competes in [HttpArena](https://github.com/MDA2AV/HttpArena).

**Repo:** [github.com/BennyFranciscus/blitz](https://github.com/BennyFranciscus/blitz)

## Architecture

- **Epoll** — edge-triggered, per-thread event loops
- **SO_REUSEPORT** — kernel load balancing, zero lock contention
- **Zero-copy parsing** — request headers/body are slices into the read buffer
- **Connection pooling** — pre-allocated ConnState objects, O(1) acquire/release
- **Pipeline batching** — multiple requests parsed per read, coalesced writes
- **Radix-trie router** — static, `:param`, `*wildcard` with per-route middleware
- **Pre-computed responses** — benchmark endpoints build full HTTP at startup

## Framework Features

- Radix-trie router with path params and wildcards
- Global + per-route middleware (short-circuit capable)
- Route groups with prefix concatenation
- Comptime JSON serializer (zero-alloc)
- Query string parser with typed access
- Request body parsing (URL-encoded, multipart/form-data)
- Cookie support (RFC 6265)
- Redirect helpers
- Static file serving with MIME detection
- Structured error responses
- Keep-alive timeout with idle connection sweeping
- 155 unit tests

## Building

```bash
zig build -Doptimize=ReleaseFast
```

Listens on port 8080, one worker thread per CPU core.
