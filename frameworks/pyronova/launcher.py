"""Launcher — spawns two Pyronova processes (HTTP plain + HTTPS).

Plain HTTP on $PORT (default 8080) and HTTPS on $PORT+1 for the json-tls
profile. A separate HTTP/2 listener on 8443 is launched when TLS certs
are present — rustls advertises ALPN h2 + http/1.1, so clients negotiate
automatically.

Why two processes: Pyronova's `app.run()` binds a single port. Running it
twice is the simplest way to serve plaintext + TLS without adding
multi-bind support to the engine for one benchmark. Each process gets
half the available CPUs so we don't over-subscribe the sub-interpreter
pool.
"""

import os
import signal
import subprocess
import sys
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
    per_proc = max(total // 2, 1)
    # IO workers sizing is NUMA-topology-aware. Two regimes:
    #
    # Multi-node (Threadripper PRO / EPYC / multi-socket Xeon): cap IO
    # at `per_proc // 4` so the accept loops + hyper socket threads
    # stay on a couple of CCDs. Letting IO spread across every CCD
    # turns every `crossbeam_channel::recv` into an Infinity-Fabric
    # round trip — Leo observed this as "baseline stops scaling past
    # 26 cores on the 3995WX" in the Arena run.
    #
    # Single-node (laptops, Apple Silicon, most cloud VMs): IO == cores.
    # The prior NUMA-only formula cost 32% throughput on an M5 Pro
    # because IO threads starved with no matching compute benefit.
    if _numa_nodes() > 1:
        io_per_proc = min(max(per_proc // 4, 4), 16)
    else:
        io_per_proc = per_proc

    base_port = int(os.environ.get("PORT", "8080"))
    tls_cert = os.environ.get("TLS_CERT", "/certs/server.crt")
    tls_key = os.environ.get("TLS_KEY", "/certs/server.key")
    have_tls = os.path.exists(tls_cert) and os.path.exists(tls_key)

    env_common = dict(os.environ)
    env_common["PYRONOVA_WORKERS"] = str(per_proc)
    env_common["PYRONOVA_IO_WORKERS"] = str(io_per_proc)
    # GIL-bridge sizing for gil=True routes under TPC. Default is 4 workers
    # + 16×4=64 channel depth — correct for typical apps with 1-2 numpy
    # routes. HttpArena's async-db / crud profiles hammer gil=True paths
    # at 1024+ concurrency, so a 64-deep channel overflows immediately
    # and every excess request 503s (PyronovaApp's bridge backpressure
    # contract). Widen to 16 workers + 8192 capacity so the DB-heavy
    # gcannon profiles see sustained throughput instead of a 503 storm.
    # Verified locally at c=4096: 15k req/s steady, zero drops.
    env_common.setdefault("PYRONOVA_GIL_BRIDGE_WORKERS", "16")
    env_common.setdefault("PYRONOVA_GIL_BRIDGE_CAPACITY", "8192")
    # Metrics / access log off; benchmarks care about throughput, not logs.
    env_common.pop("PYRONOVA_LOG", None)
    env_common.pop("PYRONOVA_METRICS", None)
    # Hard-silence the tracing subscriber. Default level is ERROR, which
    # still writes any `tracing::error!` call to stderr — under 4096-conn
    # load a single recurring error log (see the PyObjRef leak bug) drags
    # throughput by ~3× from log-pipe contention alone. OFF makes every
    # tracing macro a zero-cost no-op, matching what Actix / Helidon /
    # ASP.NET ship in their benchmark images.
    env_common["PYRONOVA_LOG_LEVEL"] = "OFF"

    procs = []

    # Plain HTTP on $base_port.
    env_plain = dict(env_common)
    env_plain["PYRONOVA_PORT"] = str(base_port)
    env_plain["PYRONOVA_HOST"] = "0.0.0.0"
    env_plain.pop("PYRONOVA_TLS_CERT", None)
    env_plain.pop("PYRONOVA_TLS_KEY", None)
    procs.append(subprocess.Popen(["python3", "app.py"], env=env_plain))

    # HTTPS on $base_port + 1 (json-tls profile target).
    if have_tls:
        env_tls = dict(env_common)
        env_tls["PYRONOVA_PORT"] = str(base_port + 1)
        env_tls["PYRONOVA_HOST"] = "0.0.0.0"
        env_tls["PYRONOVA_TLS_CERT"] = tls_cert
        env_tls["PYRONOVA_TLS_KEY"] = tls_key
        procs.append(subprocess.Popen(["python3", "app.py"], env=env_tls))

        # HTTP/2 on 8443 (baseline-h2 / static-h2 profile target). ALPN on
        # this listener advertises h2 + http/1.1; hyper's AutoBuilder picks
        # the right protocol from the handshake.
        env_h2 = dict(env_tls)
        env_h2["PYRONOVA_PORT"] = "8443"
        procs.append(subprocess.Popen(["python3", "app.py"], env=env_h2))

    def shutdown(_sig, _frame):
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass
        # give them a moment to drain gracefully; Pyronova's graceful shutdown
        # waits up to 30s for in-flight conns — the Arena harness typically
        # SIGKILLs the container anyway, but polite is polite.
        time.sleep(1)
        for p in procs:
            if p.poll() is None:
                try:
                    p.kill()
                except Exception:
                    pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Wait on the plain HTTP process; when it exits the harness is done
    # with us anyway. Terminate the others if they're still up.
    try:
        procs[0].wait()
    except Exception:
        pass
    for p in procs[1:]:
        if p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
