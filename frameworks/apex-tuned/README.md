# apex-tuned

High-performance HTTP/1.1 framework in C23 designed for many-core NUMA architectures.

## Architecture

- **Runtime**: Thread-per-core shared-nothing event loop using Linux `epoll` with per-worker `SO_REUSEPORT` listeners. Workers use kernel scheduling by default for co-located loads; `APEX_PIN_CPUS=1` enables dedicated CPU pinning.
- **Memory**: Slab-allocated connection contexts and pre-sized I/O rings. Zero dynamic allocations in the request-response path.
- **Parser**: Streaming state-machine HTTP/1.1 parser resilient to byte-level TCP fragmentation, supporting pipelining, chunked transfer decoding, and lower-cased header variants.
- **Routing & Middleware**: Trie router with route parameter extraction (`:ms`, `:count`) and query string slicing; middleware chain for compression negotiation.
- **Compression**: Brotli (level 1) and gzip encoding using pre-allocated worker compression contexts.
- **TLS**: OpenSSL 3 TLS 1.3 with session caching and zero-copy body echoing on `:8081`.

## Endpoints

- `GET /baseline11?a=X&b=Y`: Sums query parameters
- `POST /baseline11?a=X&b=Y`: Sums query parameters and body (Content-Length or chunked)
- `GET /pipeline`: Pipelining verification (`ok`)
- `GET /delay/{ms}`: Non-blocking millisecond timer delay
- `GET /json/{count}?m=N`: Transforms dataset items with `total = price * quantity * m`, compressed per `Accept-Encoding`
- `POST /echo`: Byte-for-byte body echo on port 8081 (TLS)
- `GET /static/{file}`: Static files from `/data/static`, serving `.br`/`.gz` sibling twins when accepted
