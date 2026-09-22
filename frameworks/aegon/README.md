# Aegon HttpArena Entry

[Aegon](https://github.com/UdayKhare09/Aegon) is a Linux-native C++26 asynchronous web framework powered by `io_uring` multishot primitives, coroutines, stepped SIMD vectorization, and compile-time data engines.

## Endpoints

- `GET /pipeline`: Plaintext response ("ok")
- `GET /baseline11` & `POST /baseline11`: Sum of query parameters + POST body
- `GET /baseline2` & `POST /baseline2`: HTTP/2 baseline endpoints
- `GET /delay/:ms`: Non-blocking asynchronous timeout via io_uring timer coroutines
- `GET /json/:count`: Zero-copy Glaze JSON serialization with libdeflate gzip compression
- `POST /echo`: 8Gbit verbatim binary echo over TLS

## Concurrency & CPU Sizing

Worker thread allocation respects container CPU constraints:
- Evaluates cgroup v2 (`/sys/fs/cgroup/cpu.max`) and cgroup v1 CFS bandwidth quotas.
- Evaluates CPU affinity masks (`sched_getaffinity`).
- Falls back to hardware concurrency, guaranteeing at least one worker and avoiding thread over-subscription under restricted CPU quotas (e.g. `latency-500k-8cpu`).
