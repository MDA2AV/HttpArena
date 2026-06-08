---
title: Setup
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

First invocation builds `gcannon:latest`, `h2load:latest`, `h2load-h3:local`, `wrk:local`, and `ghz:local` from `docker/*.Dockerfile`. `h2load-h3` is the slow one - expect a few minutes while quictls + ngtcp2 compile. Cached after that.

To use the same docker images with the full `benchmark.sh` driver (all profiles, CPU pinning, etc.) set `LOADGEN_DOCKER=true`:

```bash
LOADGEN_DOCKER=true ./scripts/benchmark.sh actix --save
```

## Native load generators

Install these on the host only if you want `benchmark.sh` to run in its default native mode. You can pick and choose - every tool has a docker fallback, so missing one isn't fatal as long as you don't run the profiles that need it (or you flip on `LOADGEN_DOCKER=true`).

### gcannon - h1 / pipelined / upload / api-4/16 / async-db / ws-echo

Requires Linux kernel ≥ 6.1 (`io_uring`). Build `liburing 2.9` first to match the production binary.

```bash
git clone --branch liburing-2.9 https://github.com/axboe/liburing.git
cd liburing && ./configure --prefix=/usr && make -j"$(nproc)" -C src && sudo make install -C src && cd ..

git clone https://github.com/MDA2AV/gcannon.git
cd gcannon && make && sudo cp gcannon /usr/local/bin/
```

If you'd rather not install system-wide, export `GCANNON=/path/to/gcannon/gcannon` before running the script.

### h2load - baseline-h2 / static-h2 / unary-grpc / gateway-64

Distro package - the Ubuntu 24.04 glibc build gives ~20–40% more throughput than the alpine/musl one.

```bash
sudo apt install nghttp2-client
```

### h2load-h3 - baseline-h3 / static-h3

No distro package exists. Either build it yourself from `docker/h2load-h3.Dockerfile`'s recipe (quictls → nghttp3 → ngtcp2 → nghttp2 `--enable-http3`) or use `LOADGEN_DOCKER=true` and let the docker image handle it.

### wrk - static / json-tls

```bash
sudo apt install wrk
```

### ghz - stream-grpc / stream-grpc-tls

```bash
go install github.com/bojand/ghz/cmd/ghz@latest
```

## TLS certificates

The repo ships self-signed certs in `certs/` (`server.crt` + `server.key`). Every framework container mounts them at `/certs` automatically - no action needed.

To regenerate them (optional):

```bash
openssl req -x509 -newkey rsa:2048 -keyout certs/server.key -out certs/server.crt \
  -days 365 -nodes -subj "/CN=localhost"
```

## Permission check

Confirm your user can talk to Docker without sudo:

```bash
docker ps
```

If that prints a permission error, either add your user to the `docker` group (`sudo usermod -aG docker $USER`, log out, log back in) or run the scripts as root.

Host tuning (CPU governor, sysctl, docker daemon restart, MTU, page cache drop) does use `sudo`. Without it the scripts warn and continue - you'll still get usable results, just with noisier numbers.
