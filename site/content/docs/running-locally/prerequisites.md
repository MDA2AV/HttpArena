---
title: Prerequisites
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
- **git** - image builds clone gcannon / nghttp2 / ghz source from GitHub.

## Choosing a script

| | `benchmark.sh` | `benchmark-lite.sh` |
|---|---|---|
| Who it's for | Full runs on a tuned benchmark host | Laptops, CI runners, quick local validation |
| Load generators | Native binaries by default, docker mode opt-in (`LOADGEN_DOCKER=true`) | **Always** docker, forced |
| CPU pinning | Per-profile `--cpuset-cpus` | None (container gets all cores) |
| Threads | 64 (h1) / 128 (h2) / 64 (h3) - fixed | `nproc / 2`, or `--load-threads N` |
| Profiles | All 21 | Subset (no api-4/16, json-tls, gateway-64, stream-grpc*) |
| Host tuning (CPU gov, sysctl, MTU, daemon restart) | Yes | Yes |
| Root needed | For tuning + docker | For tuning + docker |

Pick `benchmark-lite.sh` if you just want to sanity-check a framework; pick `benchmark.sh` if you're trying to reproduce leaderboard numbers.

## benchmark-lite.sh requirements

Just Docker, bash, python3. Every load-generator image is built from `docker/*.Dockerfile` on first run (first invocation takes a few minutes while `quictls` + `ngtcp2` compile for `h2load-h3`; cached after that).

You do **not** need `gcannon`, `h2load`, `h2load-h3`, `wrk`, or `ghz` installed on the host. You do not need a specific kernel for gcannon - the container already carries `liburing` 2.9.

## benchmark.sh requirements (native load-generator mode)

For the default (native) mode, install each tool the host binary. If anything is missing, set `LOADGEN_DOCKER=true` and the script falls back to the same docker images `benchmark-lite.sh` uses.

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

- **wrk** - static-file profile. Any recent build works.

  ```bash
  sudo apt install wrk
  ```

- **ghz** - gRPC streaming benchmarks.

  ```bash
  go install github.com/bojand/ghz/cmd/ghz@latest
  ```

## Permission notes

- Docker commands assume your user is in the `docker` group, or you'll hit `permission denied`.
- System tuning (`cpupower frequency-set`, `sysctl -w`, `ip link set lo mtu`, `systemctl restart docker`, `drop_caches`) uses `sudo`. Without it the script warns and continues - you still get usable results, just with less-predictable numbers.
- `--cpuset-cpus` requires cgroup v2 (default on modern Linux).
