---
title: Prerequisites
seo_title: "Prerequisites"
description: "What to install before running HttpArena locally: Docker, the load generator toolchain, and the host settings the driver expects."
weight: 1
---

What you need installed before running HttpArena benchmarks locally.

## Operating system

| OS | Supported | Notes |
|---|---|---|
| **Linux** (kernel ≥ 6.1) | ✅ Yes | The only fully-supported target. Required for `io_uring` (gcannon native), `cpupower`, the host `sysctl` knobs the tuner writes, and `--network host` behaviour Docker containers rely on. Tested primarily on Ubuntu 24.04 / 25.04. |
| **macOS** | ❌ No | Docker Desktop runs in a Linux VM; `--network host`, host-side tuning, and cgroup cpuset all behave differently. |
| **Windows** | ❌ No | The Windows driver scripts were removed. WSL2 may work for `benchmark-lite.sh`-style runs but is untested. |

`benchmark.sh` will refuse to do anything destructive without root (tuning is best-effort), but gcannon native mode, Docker `--cpuset-cpus` pinning, and the postgres sidecar all assume Linux semantics.

## Common requirements (both scripts)

- **Docker Engine ≥ 24** - framework containers, postgres sidecar, and every load-generator image run under Docker.
- **bash ≥ 4.4** - the driver uses associative arrays.
- **python3** - for result JSON aggregation (`scripts/rebuild_site_data.py`) and `meta.json` parsing.
- **curl** - readiness probes.
- **git** - image builds clone gcannon / nghttp2 source from GitHub.

## Choosing how to run

There is one driver, `benchmark.sh`. Its defaults describe the reference bench host; on any other machine you run it with a [host profile](../host-profiles/) that scales it down.

| | `benchmark.sh` | `benchmark-lite.sh` (`HOST_PROFILE=lite`) |
|---|---|---|
| Who it's for | Full runs on a tuned benchmark host | Laptops, CI runners, quick local validation |
| Load generators | Native binaries by default, Docker opt-in (`LOADGEN_DOCKER=true`) | Always Docker |
| CPU pinning | Per-profile `--cpuset-cpus` | None (containers get all cores) |
| Threads | 64 for every generator | `nproc / 2`, or `--load-threads N` |
| Profiles | All 27 | A subset of 13 (see [benchmark-lite.sh](../scripts/benchmark-lite/#profile-set)) |
| `--save` writes to | `results/` and the site data | `results-hosts/lite/` |
| Host tuning (CPU gov, sysctl, MTU, daemon restart) | Yes | Yes |
| Root needed | For tuning + docker | For tuning + docker |

Pick `benchmark-lite.sh` to sanity-check a framework or compare frameworks on your own machine; pick `benchmark.sh` to reproduce leaderboard numbers. For a specific small machine such as a Raspberry Pi, see the `rpi` profile on [Host profiles](../host-profiles/).

## Requirements with Docker load generators

Docker, bash and python3 - this covers `benchmark-lite.sh`, every other host profile and `LOADGEN_DOCKER=true`. Every load-generator image is built from `docker/*.Dockerfile` on first use (the first run takes a few minutes while `quictls` + `ngtcp2` compile for `h2load-h3`; cached after that). The images build on x86_64 and arm64.

You do **not** need `gcannon`, `h2load`, `h2load-h3`, `wrk` or `zrk` installed on the host, nor a specific kernel for gcannon - the container already carries `liburing` 2.9.

## benchmark.sh requirements (native load-generator mode)

For the default (native) mode, install each tool the host binary. If anything is missing, set `LOADGEN_DOCKER=true` and the script uses the Docker images described above instead.

- **gcannon** - io_uring HTTP/1.1, WebSocket, and `--raw` multi-template generator. Requires Linux kernel ≥ 6.1 with `io_uring` enabled.

  ```bash
  git clone --branch liburing-2.9 https://github.com/axboe/liburing.git
  cd liburing && ./configure --prefix=/usr && make -j"$(nproc)" -C src && sudo make install -C src
  cd ..
  git clone https://github.com/MDA2AV/gcannon.git
  cd gcannon && make && sudo cp gcannon /usr/local/bin/
  ```

- **h2load** - HTTP/2 and gRPC (unary) generator from the nghttp2 project.

  ```bash
  sudo apt install nghttp2-client
  ```

- **h2load-h3** - HTTP/3 over QUIC. No official distro package; the docker image (`docker/h2load-h3.Dockerfile`) builds `quictls` + `nghttp3` + `ngtcp2` + `nghttp2 --enable-http3` from source. Easiest path: use `LOADGEN_DOCKER=true` for h3 profiles.

- **wrk** - `static-tls` and `json-tls`. Any recent build works.

  ```bash
  sudo apt install wrk
  ```

- **zrk** - the fixed-rate profiles (`latency-1m`, `latency-10k`, `latency-500k-8cpu`, `8gbit`). No distro package; if no `zrk` binary is on the `PATH`, `benchmark.sh` builds and uses the `zrk:local` image from `docker/zrk.Dockerfile` automatically.


## Permission notes

- Docker commands assume your user is in the `docker` group, or you'll hit `permission denied`.
- System tuning (`cpupower frequency-set`, `sysctl -w`, `ip link set lo mtu`, `systemctl restart docker`, `drop_caches`) uses `sudo`. Without it the script warns and continues - you still get usable results, just with less-predictable numbers.
- `--cpuset-cpus` requires cgroup v2 (default on modern Linux).
