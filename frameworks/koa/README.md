# Koa

[Koa](https://github.com/koajs/koa) (~36k ⭐) is an expressive middleware framework for Node.js, designed by the team behind Express to leverage async/await for cleaner control flow.

## Key Features
- Cascading async/await middleware (no callback hell)
- Lightweight core (~600 LOC, no bundled middleware)
- Context object (`ctx`) encapsulates request/response
- Built by TJ Holowaychick and the Express team

## Implementation Details
- Koa 2.x with koa-router
- Cluster mode (one worker per CPU core)
- Pre-computed JSON and gzip buffers
- Raw stream body reading (no body-parser)
- better-sqlite3 with mmap for `/db`
- HTTP/2 via native `http2` module
