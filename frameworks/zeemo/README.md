# zeemo

Bare-metal Zig HTTP/1.1 server for the [HttpArena](https://www.http-arena.com/) benchmark.

- **Engine:** Linux `io_uring` (multishot accept, direct syscalls — no liburing wrapper)
- **Concurrency:** one process per allowed CPU via `SO_REUSEPORT`, each pinned with `sched_setaffinity`, shared-nothing
- **Parser:** hand-written incremental HTTP/1.1 (TCP fragmentation, `Content-Length`, `Transfer-Encoding: chunked`, keep-alive, pipelining)
- **Runtime:** ~370 KB static musl binary on `scratch`

Supported HttpArena profiles:

- `baseline` — `GET/POST /baseline11?a=…&b=…`, returns the integer sum
- `pipelined` — `GET /pipeline`, returns `ok` (16 requests batched per connection)
- `limited-conn` — same `/baseline11` endpoint as baseline, connection closes after 10 requests
- `json` — `GET /json/{count}?m=…`, renders the first `count` items of `/data/dataset.json` with `total = price * quantity * m`

The io_uring loop drains all pipelined requests from one `recv()` and emits the responses as a single batched `send()`. JSON responses use a fixed-length header prefix (Content-Length padded to 5 digits with leading zeros) so every response starts at offset 0 of the per-connection write buffer — pipelined batches concatenate without a `memmove`.

## Build

```sh
zig build --release=fast                       # native
zig build -Dtarget=x86_64-linux-musl --release=fast
```

## Run

```sh
docker build -t zeemo .
docker run --rm -p 8080:8080 \
    --ulimit memlock=-1:-1 \
    -v /path/to/dataset.json:/data/dataset.json:ro \
    zeemo
```

On OrbStack the default seccomp profile blocks `io_uring_setup`; add
`--security-opt seccomp=unconfined` locally. The HttpArena bench machine
(Ubuntu 24.04) allows io_uring by default.

## Tests

```sh
zig test src/http.zig
zig test src/dataset.zig
zig test src/handlers.zig
```

`scripts/local-validate.sh` runs the HttpArena validation suite (17 checks
covering baseline, anti-cheat, TCP fragmentation, and JSON) against a
local container.
