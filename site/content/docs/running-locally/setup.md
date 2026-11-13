---
title: Setup
seo_title: "Setup"
description: "Clone HttpArena and install the native load generators, or take the Docker-only path if you would rather not build them."
weight: 2
---

Clone the repo and (optionally) install native load generators. If you'd rather skip the native install, jump straight to the [Docker-only path](#docker-only-path).

## Clone the repository

```bash
git clone https://github.com/MDA2AV/HttpArena.git
cd HttpArena
```

## Docker-only path

The fast road: install nothing, let the scripts build everything.

```bash
./scripts/benchmark-lite.sh actix baseline
```

First invocation builds `gcannon:latest`, `h2load:latest`, `h2load-h3:local`, and `wrk:local` from `docker/*.Dockerfile`. `h2load-h3` is the slow one - expect a few minutes while quictls + ngtcp2 compile. Cached after that. (The `zrk:local` image for the fixed-rate profiles is built by `benchmark.sh` when needed; for `benchmark-lite.sh` build it yourself with `docker build -t zrk:local -f docker/zrk.Dockerfile docker/`.)

To use the same docker images with the full `benchmark.sh` driver (all profiles, CPU pinning, etc.) set `LOADGEN_DOCKER=true`:

```bash
LOADGEN_DOCKER=true ./scripts/benchmark.sh actix --save
```

## Native load generators

Install these on the host only if you want `benchmark.sh` to run in its default native mode. You can pick and choose - every tool has a docker fallback, so missing one isn't fatal as long as you don't run the profiles that need it (or you flip on `LOADGEN_DOCKER=true`).

### gcannon - baseline / pipelined / limited-conn / async / json-comp / async-db / fortunes / WebSocket

Requires Linux kernel ≥ 6.1 (`io_uring`). Build `liburing 2.9` first to match the production binary.

```bash
git clone --branch liburing-2.9 https://github.com/axboe/liburing.git
cd liburing && ./configure --prefix=/usr && make -j"$(nproc)" -C src && sudo make install -C src && cd ..

git clone https://github.com/MDA2AV/gcannon.git
cd gcannon && make && sudo cp gcannon /usr/local/bin/
```

If you'd rather not install system-wide, export `GCANNON=/path/to/gcannon/gcannon` before running the script.

### h2load - HTTP/2, h2c, gRPC, gateway-64 / production-stack

Distro package - the Ubuntu 24.04 glibc build gives ~20–40% more throughput than the alpine/musl one.

```bash
sudo apt install nghttp2-client
```

### h2load-h3 - baseline-h3 / static-h3 / gateway-h3

No distro package exists. Either build it yourself from `docker/h2load-h3.Dockerfile`'s recipe (quictls → nghttp3 → ngtcp2 → nghttp2 `--enable-http3`) or use `LOADGEN_DOCKER=true` and let the docker image handle it.

### wrk - static-tls / json-tls

```bash
sudo apt install wrk
```

### zrk - latency-1m / latency-10k / latency-500k-8cpu / 8gbit

No distro package. You don't have to install anything: when no `zrk` binary is on the `PATH`, `benchmark.sh` builds the `zrk:local` image from `docker/zrk.Dockerfile` and runs it in docker.


## Permission check

Confirm your user can talk to Docker without sudo:

```bash
docker ps
```

If that prints a permission error, either add your user to the `docker` group (`sudo usermod -aG docker $USER`, log out, log back in) or run the scripts as root.

Host tuning (CPU governor, sysctl, docker daemon restart, MTU, page cache drop) does use `sudo`. Without it the scripts warn and continue - you'll still get usable results, just with noisier numbers.
