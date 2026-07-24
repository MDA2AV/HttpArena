# Hical

[Hical](https://github.com/Hical61/Hical) is a modern C++20/26 high-performance
web framework built on Boost.Asio.

## Features

- Coroutine-based async I/O (`boost::asio::awaitable<T>`)
- Three-tier PMR memory pool (global / thread-local / request-level)
- Zero-copy HTTP parsing (picohttpparser + stack-allocated `phr_header[64]`)
- SO_REUSEPORT multi-acceptor model on Linux
- Self-developed WebSocket stack (RFC 6455, permessage-deflate)
- Dual-track C++26 reflection layer (native P2996 / C++20 macro fallback)

## Test Types

- baseline, pipelined, limited-conn
- json
- upload
- static
- echo-ws

## Dependencies

- C++20 (GCC 14+)
- Boost (Asio, JSON, System)
- OpenSSL
- zlib
