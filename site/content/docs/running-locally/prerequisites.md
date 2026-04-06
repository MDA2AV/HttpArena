---
title: Prerequisites
weight: 1
---

Required tools and system dependencies to run HttpArena benchmarks.

## Quick start (benchmark-lite.sh)

If you just want to run benchmarks on your own machine, you only need:

- **Docker Engine**
- **curl**, **python3**, **bc**

The lite script (`benchmark-lite.sh`) builds gcannon and h2load as Docker images automatically. No native toolchain, no io_uring, no specific kernel version needed. See the [benchmark-lite.sh reference](../scripts/benchmark-lite) for details.

## Full setup (benchmark.sh)

For the full benchmark suite with CPU pinning and maximum performance:

### Dependencies

- **Docker** — each framework runs inside a container
- **gcannon** — the io_uring-based HTTP/1.1 load generator ([GitHub](https://github.com/MDA2AV/gcannon))
- **h2load** — HTTP/2 load generator from nghttp2 (for `baseline-h2` and `static-h2` profiles)
- **oha** — HTTP/3 load generator with QUIC support (for `baseline-h3` and `static-h3` profiles) ([GitHub](https://github.com/hatoo/oha))
- **Linux** — gcannon requires io_uring (kernel 6.1+)
- **curl** and **bc** — used by the benchmark script

## Installing h2load

```bash
sudo apt install nghttp2-client
```

## Installing gcannon

```bash
git clone https://github.com/MDA2AV/gcannon.git
cd gcannon
make
sudo cp gcannon /usr/local/bin/
```

## Installing oha

```bash
cargo install oha
```
