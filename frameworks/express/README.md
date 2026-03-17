# Express

[Express](https://github.com/expressjs/express) (~69k ⭐) — the most widely used backend framework in the JavaScript ecosystem. Fast, unopinionated, minimalist web framework for Node.js.

## Setup

- **Express 5.x** with Node.js 22
- **Cluster mode** — one worker per CPU core
- **better-sqlite3** for `/db` endpoint (mmap, read-only)
- **HTTP/2** on port 8443 (native `http2` module, raw handler for performance)
- **Pre-computed gzip** for `/compression`

## Why Express?

HttpArena already has bare `node`, `fastify`, `ultimate-express`, `hono`, and `bun` — but not vanilla Express itself. Express is the framework that started it all for Node.js web development.

The key comparisons:
- **Express vs Fastify**: The classic Node.js framework showdown — Express's flexibility vs Fastify's schema-based speed
- **Express vs ultimate-express**: How does the original compare to its high-performance reimplementation?
- **Express vs bare node**: How much overhead does the Express middleware layer actually add?
