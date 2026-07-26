"""Launcher — spawns ONE Pyronova process serving all ports simultaneously.

Plain HTTP on $PORT (default 8080). When TLS certs are present, HTTPS is
also served on $PORT+1 (json-tls profile) and 8443 (baseline-h2 / static-h2
profile) via PYRONOVA_TLS_PORTS — all from the same process.

Each TPC thread creates its own SO_REUSEPORT socket on every port, so all
cores serve all profiles simultaneously. This gives every profile access to
all CPUs, unlike the old two-process approach that split cores 50/50.
"""

import os
import signal
import subprocess
import sys
import threading
import time


def _cpu_count() -> int:
    try:
        return max(len(os.sched_getaffinity(0)), 1)
    except AttributeError:
        return max(os.cpu_count() or 1, 1)


def _numa_nodes() -> int:
    """How many NUMA nodes does the kernel see? 1 on UMA systems
    (laptops, Apple Silicon, single-socket AMD/Intel desktop),
    2+ on multi-CCD Threadripper/EPYC and multi-socket boxes."""
    try:
        return max(
            sum(1 for d in os.listdir("/sys/devices/system/node") if d.startswith("node")),
            1,
        )
    except (FileNotFoundError, PermissionError):
        return 1


def main() -> int:
    total = _cpu_count()
    per_proc = total
    io_per_proc = per_proc

    base_port = int(os.environ.get("PORT", "8080"))
    tls_cert = os.environ.get("TLS_CERT", "/certs/server.crt")
    tls_key = os.environ.get("TLS_KEY", "/certs/server.key")
    have_tls = os.path.exists(tls_cert) and os.path.exists(tls_key)

    env = dict(os.environ)
    # PYRONOVA_WORKERS controls TPC thread count in TPC mode (one thread per
    # logical CPU). Rust's auto-detect uses physical_core_count() which misses
    # hyperthreads — on a 32C/64T Threadripper that would give 32; we want 64.
    env["PYRONOVA_WORKERS"] = str(per_proc)
    env["PYRONOVA_HOST"] = "0.0.0.0"
    env["PYRONOVA_PORT"] = str(base_port)
    # GIL-bridge sizing for gil=True routes under TPC. Default is 4 workers
    # + 16×4=64 channel depth — correct for typical apps with 1-2 numpy
    # routes. HttpArena's async-db / crud profiles hammer gil=True paths
    # at 1024+ concurrency, so a 64-deep channel overflows immediately
    # and every excess request 503s (PyronovaApp's bridge backpressure
    # contract). Widen to 16 workers + 8192 capacity so the DB-heavy
    # gcannon profiles see sustained throughput instead of a 503 storm.
    # Verified locally at c=4096: 15k req/s steady, zero drops.
    env.setdefault("PYRONOVA_GIL_BRIDGE_WORKERS", "16")
    env.setdefault("PYRONOVA_GIL_BRIDGE_CAPACITY", "8192")
    # Metrics / access log off; benchmarks care about throughput, not logs.
    env.pop("PYRONOVA_LOG", None)
    env.pop("PYRONOVA_METRICS", None)
    # Hard-silence the tracing subscriber. Default level is ERROR, which
    # still writes any `tracing::error!` call to stderr — under 4096-conn
    # load a single recurring error log (see the PyObjRef leak bug) drags
    # throughput by ~3× from log-pipe contention alone. OFF makes every
    # tracing macro a zero-cost no-op, matching what Actix / Helidon /
    # ASP.NET ship in their benchmark images.
    env["PYRONOVA_LOG_LEVEL"] = "OFF"

    if have_tls:
        env["PYRONOVA_TLS_CERT"] = tls_cert
        env["PYRONOVA_TLS_KEY"] = tls_key
        env["PYRONOVA_TLS_PORTS"] = f"{base_port + 1},8443"
    else:
        env.pop("PYRONOVA_TLS_CERT", None)
        env.pop("PYRONOVA_TLS_KEY", None)
        env.pop("PYRONOVA_TLS_PORTS", None)

    proc = subprocess.Popen(["python3", "app.py"], env=env)

    def shutdown(_sig, _frame):
        # Signal handlers must not block — offload the wait+kill to a thread.
        def _cleanup():
            import logging as _log
            try:
                proc.terminate()
            except Exception:
                _log.warning("launcher: terminate failed for pid %s", proc.pid, exc_info=True)
            # give it a moment to drain gracefully; Pyronova's graceful
            # shutdown waits up to 30s for in-flight conns — Arena harness
            # typically SIGKILLs the container anyway, but polite is polite.
            time.sleep(1)
            if proc.poll() is None:
                try:
                    proc.kill()
                except Exception:
                    _log.warning("launcher: kill failed for pid %s", proc.pid, exc_info=True)
            # os._exit terminates all threads (including this daemon thread);
            # sys.exit(0) from a daemon thread only kills the daemon thread.
            os._exit(0)
        threading.Thread(target=_cleanup, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    import logging as _log
    try:
        rc = proc.wait()
        if rc != 0:
            _log.warning("launcher: process exited with code %d", rc)
    except Exception:
        _log.warning("launcher: wait() failed", exc_info=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
