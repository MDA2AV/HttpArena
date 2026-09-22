# Aegon HttpArena Entry

[Aegon](https://github.com/UdayKhare09/Aegon) is a Linux-native C++26 asynchronous web framework powered by `io_uring` multishot primitives, coroutines, stepped SIMD vectorization, and compile-time data engines.

## Endpoints

- `GET /pipeline`: Plaintext response ("ok")
- `GET /baseline11` & `POST /baseline11`: Sum of query parameters + POST body
- `GET /baseline2` & `POST /baseline2`: HTTP/2 baseline endpoints
- `GET /delay/:ms`: Asynchronous non-blocking delayed response
- `GET /json/:count`: Glaze JSON serialization with libdeflate gzip compression
- `POST /echo`: 8Gbit verbatim binary echo over TLS
