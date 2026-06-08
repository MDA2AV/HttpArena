---
title: Manual load testing
weight: 4
---

Sometimes you want to start a framework yourself, poke at individual endpoints, try different flags, or run a load generator outside the benchmark harness altogether. This page is the "bring your own server, fire a docker load-gen at it" workflow.

## When to use this

- Iterating on a framework implementation and you want fast feedback without the full tuning / build pipeline.
- Trying a different connection count, duration, or request template than any stock profile uses.
- Debugging a single endpoint in isolation.
- Running a load generator against a server that isn't in `frameworks/` at all - anything on `localhost` works.

If you want reproducible numbers that match the leaderboard, use `benchmark.sh`. This page is for the in-between.

## Step 1 - start the server

### Option A: use `scripts/run.sh`

Starts a framework container interactively with the same mounts the benchmark uses. `Ctrl+C` to stop.

```bash
./scripts/run.sh actix
```

This exposes `8080` (HTTP/1.1, h2c gRPC), `8443` (HTTPS / HTTP/2 / HTTP/3 / gRPC-TLS), and `8081` (h1 TLS for `json-tls`).

If you need postgres for `async-db` / `api-*`:

```bash
docker run -d --name httparena-postgres --network host \
    -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=benchmark \
    -v "$(pwd)/data/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
    postgres:18 -c max_connections=256
```

### Option B: your own binary

Any server on `localhost:8080` (or wherever) works. The load generators don't care what's on the other end.

## Step 2 - build the load-generator images once

If you've run `benchmark-lite.sh` or `LOADGEN_DOCKER=true ./scripts/benchmark.sh ...` at least once, these already exist. Otherwise build them up front - it's a one-off cost:

```bash
docker build -t gcannon:latest    -f docker/gcannon.Dockerfile    docker
docker build -t h2load:latest     -f docker/h2load.Dockerfile     docker
docker build -t h2load-h3:local   -f docker/h2load-h3.Dockerfile  docker
docker build -t wrk:local         -f docker/wrk.Dockerfile        docker
docker build -t ghz:local         -f docker/ghz.Dockerfile        docker
```

The slow one is `h2load-h3:local` (compiles quictls + nghttp3 + ngtcp2 + nghttp2 --enable-http3 from source - 5–10 minutes). Everything else is under a minute.

## Step 3 - run a load generator

Every image ships with the tool as its `ENTRYPOINT`, so `docker run <image> <tool-args>` works directly. Always use `--network host` so the container can reach `localhost`.

A handy alias for brevity. The `memlock` and `seccomp` flags are **required** for gcannon - without them `io_uring_queue_init` returns `Operation not permitted` and gcannon exits silently with zero requests.

```bash
DFLAGS='--rm --network host --ulimit nofile=1048576:1048576 --ulimit memlock=-1:-1 --security-opt seccomp=unconfined'
```

### gcannon - HTTP/1.1, WebSocket, `--raw` templates

```bash
# Baseline: 512 connections, 64 threads, 5s
docker run $DFLAGS gcannon:latest \
    http://localhost:8080/baseline11?a=1\&b=1 \
    -c 512 -t 64 -d 5s -p 1

# Pipelined (depth 16)
docker run $DFLAGS gcannon:latest \
    http://localhost:8080/pipeline \
    -c 512 -t 64 -d 5s -p 16

# Multi-template raw request rotation (mount repo's requests/ dir read-only)
docker run $DFLAGS \
    -v "$(pwd)/requests:/requests:ro" \
    gcannon:latest http://localhost:8080 \
    --raw /requests/get.raw,/requests/json-get.raw,/requests/async-db-get.raw \
    -c 1024 -t 64 -d 10s

# WebSocket echo
docker run $DFLAGS gcannon:latest \
    http://localhost:8080/ws --ws \
    -c 512 -t 64 -d 5s
```

Useful flags: `-r <N>` force-reconnect every N requests (`0` = keep-alive forever), `-s <code>` expected status, `--recv-buf <bytes>` receive buffer size, `--json` machine-readable output.

#### Dynamic placeholders in raw templates

Raw request files support `{RAND:min:max}` and `{SEQ:start}` placeholders that are substituted per-request at send time. Useful for CRUD benchmarks where each request should target a different database row:

```bash
# Template with {RAND} - each request reads a random item
printf 'GET /crud/{RAND:1:100000} HTTP/1.1\r\nHost: localhost:8080\r\n\r\n' > /tmp/crud-read.raw

# Template with {SEQ} - each request creates a unique item
printf 'POST /crud HTTP/1.1\r\nHost: localhost:8080\r\nContent-Type: application/json\r\nContent-Length: 72\r\n\r\n{"id":{SEQ:100001},"name":"Bench","category":"test","price":100,"qty":50}' > /tmp/crud-create.raw

# Mix them - gcannon round-robins across templates
docker run $DFLAGS \
    -v /tmp:/requests:ro \
    gcannon:latest http://localhost:8080 \
    --raw /requests/crud-read.raw,/requests/crud-create.raw \
    -c 512 -t 64 -d 5s
```

Values are zero-padded to a fixed width so `Content-Length` stays correct. `{RAND}` uses per-connection RNG (no contention), `{SEQ}` uses a global atomic counter (unique across all threads).

### h2load - HTTP/2 and h2/h2c gRPC unary

```bash
# HTTP/2 over TLS, 256 connections, 100 streams/conn
docker run $DFLAGS h2load:latest \
    https://localhost:8443/baseline2?a=1\&b=1 \
    -c 256 -m 100 -t 128 -D 5

# gRPC unary over h2c (need a prebuilt request body)
docker run $DFLAGS \
    -v "$(pwd)/requests:/requests:ro" \
    h2load:latest \
    http://localhost:8080/benchmark.BenchmarkService/GetSum \
    -d /requests/grpc-sum.bin \
    -H 'content-type: application/grpc' -H 'te: trailers' \
    -c 256 -m 100 -t 128 -D 5
```

`-D` takes seconds (not `5s`), `-m` is the max concurrent streams per connection, `-t` is worker threads.

### h2load-h3 - HTTP/3 over QUIC

Same binary family as h2load, same flags, plus `--alpn-list=h3`:

```bash
docker run $DFLAGS h2load-h3:local \
    --alpn-list=h3 \
    https://localhost:8443/baseline2?a=1\&b=1 \
    -c 64 -m 64 -t 64 -D 5
```

If h3 errors out with `connect error`, bump the host's UDP buffer sizes - the benchmark driver sets these to 7.5 MB but a plain shell doesn't inherit them:

```bash
sudo sysctl -w net.core.rmem_max=7500000 net.core.wmem_max=7500000
```

### wrk - static file rotation, json-tls

`wrk` needs the lua scripts from `requests/` for multi-URL rotation:

```bash
docker run $DFLAGS \
    -v "$(pwd)/requests:/requests:ro" \
    wrk:local \
    -t 64 -c 1024 -d 5s \
    -s /requests/static-rotate.lua \
    http://localhost:8080
```

A simple single-URL test (no script, no rotation):

```bash
docker run $DFLAGS wrk:local \
    -t 8 -c 256 -d 5s \
    http://localhost:8080/baseline11?a=1\&b=1
```

### ghz - gRPC streaming

ghz needs the `.proto` file mounted in. It emits a big text summary by default; add `--format=json` for scriptable output.

```bash
# Unary, h2c
docker run $DFLAGS \
    -v "$(pwd)/requests:/requests:ro" \
    ghz:local \
    --insecure --proto /requests/benchmark.proto \
    --call benchmark.BenchmarkService/GetSum \
    -d '{"a":1,"b":2}' \
    --connections 64 -c 256 -z 5s \
    localhost:8080

# Bidi-ish streaming: one call fans out 5000 messages, 64 concurrent connections
docker run $DFLAGS \
    -v "$(pwd)/requests:/requests:ro" \
    ghz:local \
    --insecure --proto /requests/benchmark.proto \
    --call benchmark.BenchmarkService/StreamSum \
    -d '{"a":1,"b":2,"count":5000}' \
    --connections 64 -c 256 -n 50000 \
    localhost:8080
```

For TLS (`grpc-tls` / `stream-grpc-tls`) use `--skipTLS` instead of `--insecure` and point at port `8443`.

## CPU pinning (optional)

The benchmark script pins the load generator to one half of the CPU topology via `--cpuset-cpus` to avoid stealing cycles from the framework. For a manual run you can do the same:

```bash
docker run $DFLAGS --cpuset-cpus=32-63,96-127 gcannon:latest ...
```

On a laptop there's no point - the container will get more cores than the server has anyway. Just leave it off.

## Reusing the benchmark's request templates

Everything under `requests/` is fair game:

| File | What it is |
|---|---|
| `requests/get.raw`, `post_cl.raw`, `post_chunked.raw` | Raw HTTP/1.1 requests for `--raw` mode. |
| `requests/json-{1,5,10,...}.raw` | Different JSON body sizes for the `json` profile. |
| `requests/async-db-{5,10,20,35,50}.raw` | Different `limit=N` query variants. |
| `requests/upload-{500k,2m,10m,20m}.raw` | Upload bodies for the `upload` profile. |
| `requests/static-rotate.lua` / `json-tls-rotate.lua` | wrk rotation scripts. |
| `requests/static-h2-uris.txt` | URI list for `h2load -i` (static-h2 / static-h3). |
| `requests/benchmark.proto` | gRPC service definition. |
| `requests/grpc-sum.bin` | Prebuilt `GetSum` gRPC body for h2load. |

Mount the directory read-only into any tool: `-v "$(pwd)/requests:/requests:ro"`.

## Parsing the output

The benchmark driver's parsers live in `scripts/lib/tools/*.sh` - `gcannon_parse`, `h2load_parse`, `h2load_h3_parse`, `wrk_parse`, `ghz_parse`. If you want to script on top of a manual run, source one of those modules:

```bash
source scripts/lib/common.sh
source scripts/lib/tools/gcannon.sh

out=$(docker run --rm --network host \
    --ulimit memlock=-1:-1 --security-opt seccomp=unconfined \
    gcannon:latest \
    "http://localhost:8080/baseline11?a=1&b=1" \
    -c 512 -t 64 -d 5s -p 1 2>&1)

gcannon_parse "" "$out"
# rps=3401583
# avg_lat=123us
# p99_lat=287us
# ...
```

## When your numbers don't match the leaderboard

A manual docker run is ~10–20% slower than a native `benchmark.sh` run on the same hardware because the docker daemon restart, CPU governor flip, loopback MTU change, and kernel socket tuning are all skipped. For relative comparisons between frameworks on your own machine it's close enough; for absolute numbers use `benchmark.sh`.
