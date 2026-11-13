"""Launcher — runs ONE mipyre process serving every port.

Plain HTTP on $PORT (default 8080) and on 8082 (baseline-h2c / json-h2c: a
plain listener answers HTTP/1.1 and HTTP/2 with prior knowledge). When TLS
certs are present, HTTPS is also served on $PORT+1 (json-tls / static-tls /
8gbit) and 8443 (baseline-h2 / static-h2). Every setting reaches the engine as
a MIPYRE_* variable (`server_env`); the engine refuses a MIPYRE_* name it does
not read, so a misspelt or renamed setting stops the start instead of being
ignored.

Each TPC thread creates its own SO_REUSEPORT socket on every port, so all
cores serve all profiles simultaneously.
"""

import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass


# baseline-h2c / json-h2c: HttpArena's fixed cleartext HTTP/2 port.
H2C_PORT = 8082
# baseline-h2 / static-h2: HttpArena's fixed TLS HTTP/2 port.
H2_TLS_PORT = 8443


@dataclass(frozen=True)
class TlsFiles:
    cert: str
    key: str


def server_env(threads: int, port: int, tls: TlsFiles | None) -> dict[str, str]:
    """Return the engine settings for this container, by environment variable."""
    env = {
        "MIPYRE_THREADS": str(threads),
        "MIPYRE_HOST": "0.0.0.0",
        "MIPYRE_PORT": str(port),
        "MIPYRE_EXTRA_PLAIN_PORTS": str(H2C_PORT),
        # The async profile holds up to 32000 requests at once; the default
        # queue (128 per async worker) answers the rest 503.
        "MIPYRE_ASYNC_QUEUE_CAPACITY": "40000",
    }
    if tls is None:
        return env
    return env | {
        "MIPYRE_TLS_CERT": tls.cert,
        "MIPYRE_TLS_KEY": tls.key,
        "MIPYRE_EXTRA_TLS_PORTS": f"{port + 1},{H2_TLS_PORT}",
    }


def _physical_cores() -> int:
    """Physical cores among the CPUs this process may run on (its affinity
    mask: the container's cpuset), counting SMT siblings once.

    One TPC thread per physical core is what the engine is built for: two
    threads pinned to SMT siblings run the same code path and fight over one
    core's L1/L2 (measured -50% per thread on a 7840HS). sysfs lists every CPU
    of the host whatever the cpuset (64 cores for HttpArena's 0-31,64-95 of a
    64C/128T host), so the count starts from the affinity mask.
    """
    try:
        allowed = sorted(os.sched_getaffinity(0))
    except AttributeError:  # not Linux
        return max(os.cpu_count() or 1, 1)
    cores = set()
    for cpu in allowed:
        path = f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"
        try:
            with open(path) as f:
                cores.add(f.read().strip())
        except OSError:
            cores.add(f"cpu{cpu}")  # topology unknown: count the CPU as its own core
    return max(len(cores), 1)


def _parse_port(raw: str) -> int:
    """Parse the PORT env var, failing with a clear message instead of a
    raw ValueError traceback from int()."""
    try:
        port = int(raw)
    except (TypeError, ValueError):
        raise SystemExit(f"invalid PORT: {raw!r} is not an integer")
    if not (1 <= port <= 65535):
        raise SystemExit(f"invalid PORT: {port} out of range 1-65535")
    return port


def main() -> int:
    base_port = _parse_port(os.environ.get("PORT", "8080"))
    tls_cert = os.environ.get("TLS_CERT", "/certs/server.crt")
    tls_key = os.environ.get("TLS_KEY", "/certs/server.key")
    have_tls = os.path.exists(tls_cert) and os.path.exists(tls_key)

    tls = None
    if have_tls:
        if base_port + 1 > 65535:
            raise SystemExit(
                f"invalid TLS port: PORT={base_port} leaves no room for the "
                f"TLS companion port {base_port + 1} (max 65535); use PORT<=65534"
            )
        tls = TlsFiles(tls_cert, tls_key)
    # One TPC thread per physical core (32 on HttpArena's cpuset), not one per
    # logical CPU: two threads on SMT siblings of one core fight over its L1/L2.
    env = os.environ | server_env(_physical_cores(), base_port, tls)

    try:
        proc = subprocess.Popen(["python3", "app.py"], env=env)
    except FileNotFoundError:
        raise SystemExit("launcher: 'python3' not found on PATH")
    except OSError as exc:
        raise SystemExit(f"launcher: failed to start 'python3 app.py': {exc}")

    # Guard so repeated SIGTERM/SIGINT don't each spawn a cleanup thread,
    # all racing on terminate()/kill() and os._exit.
    _shutting_down = threading.Event()

    def shutdown(_sig, _frame):
        # Signal handlers must not block — offload the wait+kill to a thread.
        # First signal wins; later signals are no-ops until exit.
        if _shutting_down.is_set():
            return
        _shutting_down.set()

        def _cleanup():
            import logging as _log
            try:
                proc.terminate()
            except Exception:
                _log.warning("launcher: terminate failed for pid %s", proc.pid, exc_info=True)
            # give it a moment to drain gracefully; mipyre's graceful
            # shutdown waits up to 30s for in-flight conns — Arena harness
            # typically SIGKILLs the container anyway, but polite is polite.
            time.sleep(1)
            if proc.poll() is None:
                try:
                    proc.kill()
                except Exception:
                    _log.warning("launcher: kill failed for pid %s", proc.pid, exc_info=True)
            # Propagate the child's real exit code rather than masking every
            # shutdown as success. If the child already exited non-zero (e.g.
            # a benchmark crash that itself raised the signal), os._exit(0)
            # would hide that failure from CI.
            # SIGKILL is delivered asynchronously, so poll() can still return
            # None right after kill() — wait() blocks until the process is
            # actually reaped and yields the true exit code. Bounded so a wedged child can't hang shutdown.
            try:
                rc = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Child still wedged after SIGKILL + 10s — give up waiting and
                # fall back to a non-blocking poll (likely still None).
                rc = proc.poll()
            except Exception:
                # OSError or other unexpected failures from wait() — log so the
                # cause is visible rather than silently masked.
                _log.warning("launcher: wait() failed during shutdown", exc_info=True)
                rc = proc.poll()
            # os._exit terminates all threads (including this daemon thread);
            # sys.exit(0) from a daemon thread only kills the daemon thread.
            os._exit(1 if rc is None else (128 + abs(rc) if rc < 0 else rc))
        threading.Thread(target=_cleanup, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    import logging as _log
    try:
        rc = proc.wait()
        if rc != 0:
            _log.warning("launcher: process exited with code %d", rc)
        # Propagate child rc so CI/CD pipelines see real failures.
        return rc
    except Exception:
        _log.warning("launcher: wait() failed", exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
