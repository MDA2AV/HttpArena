"""Spawn HTTP + HTTPS BlackBull workers per HttpArena framework spec.

HttpArena's `scripts/validate.sh` uses four ports:

  :8080  HTTP/1.1 cleartext (also serves h2c via prior-knowledge)
  :8081  HTTPS HTTP/1.1     — the ``json-tls`` profile probes here
  :8082  h2c only           — BlackBull's HTTP/2 preface auto-detect
                              handles h2c on the same app/workers as
                              :8080.  The dedicated :8082 listener is
                              opened so validate.sh's port-open probe
                              succeeds even when ``baseline-h2c`` /
                              ``json-h2c`` profiles aren't claimed in
                              ``meta.json``.
  :8443  HTTPS HTTP/2 ALPN  — ``baseline-h2`` / ``static-h2`` probe here

BlackBull claims both H/1.1+TLS and H/2+TLS, so :8081 and :8443 are
exposed simultaneously — same BlackBull, same cert, different
listeners.  ALPN negotiates HTTP/1.1 on :8081 connections and h2
on :8443.

Parallel ``subprocess.Popen`` per port, all terminated on SIGTERM /
SIGINT.  No port-readiness gating — BlackBull's bind happens in
``serve()`` as the first awaited step, so by the time the
subprocess is alive the kernel TCP accept queue is open.
"""
import multiprocessing
import os
import signal
import subprocess
import sys
import time


HTTP_PORT      = int(os.environ.get('HTTPARENA_HTTP_PORT',      '8080'))
HTTPS_H1_PORT  = int(os.environ.get('HTTPARENA_HTTPS_H1_PORT',  '8081'))
H2C_PORT       = int(os.environ.get('HTTPARENA_H2C_PORT',       '8082'))
HTTPS_H2_PORT  = int(os.environ.get('HTTPARENA_HTTPS_H2_PORT',  '8443'))
TLS_CERT       = os.environ.get('TLS_CERT', '/certs/server.crt')
TLS_KEY        = os.environ.get('TLS_KEY',  '/certs/server.key')

# Worker count — explicit override via WEB_WORKERS env var (the
# harness sets this when sweeping nproc/2 / nproc / nproc×2).
# Otherwise honour cgroup-aware CPU affinity if the platform exposes
# it (Linux), else fall back to multiprocessing.cpu_count().  Capped
# at 128 as a sanity guard.
_web_workers = os.environ.get('WEB_WORKERS', '').strip()
if _web_workers.isdigit() and int(_web_workers) > 0:
    WRK_COUNT = min(int(_web_workers), 128)
else:
    try:
        WRK_COUNT = min(len(os.sched_getaffinity(0)), 128)
    except (AttributeError, OSError):
        WRK_COUNT = multiprocessing.cpu_count()

PY = sys.executable
APP = os.path.join(os.path.dirname(__file__), 'app.py')

# Which listeners to spawn.  validate.sh requires all four;
# benchmark profiles only ever load one at a time, so disabling the
# idle three during a benchmark removes most of the worker-process
# scheduler pressure.  Comma-separated list of
# {"http","https-h1","h2c","https-h2"}; default = all four (so
# validate.sh's port-open probe finds :8082 listening).
_ports_env = os.environ.get('BB_HTTPARENA_PORTS', 'http,https-h1,h2c,https-h2')
_enabled_ports = {p.strip() for p in _ports_env.split(',') if p.strip()}


def _spawn(extra):
    return subprocess.Popen([PY, APP, *extra, '--workers', str(WRK_COUNT)])


http_proc       = _spawn(['--port', str(HTTP_PORT)]) if 'http' in _enabled_ports else None
h2c_proc        = _spawn(['--port', str(H2C_PORT)])  if 'h2c'  in _enabled_ports else None
https_h1_proc   = None
https_h2_proc   = None
if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
    if 'https-h1' in _enabled_ports:
        https_h1_proc = _spawn(['--port', str(HTTPS_H1_PORT),
                                '--cert', TLS_CERT, '--key', TLS_KEY])
    if 'https-h2' in _enabled_ports:
        https_h2_proc = _spawn(['--port', str(HTTPS_H2_PORT),
                                '--cert', TLS_CERT, '--key', TLS_KEY])
else:
    sys.stderr.write(
        f'launcher: TLS cert/key not present at {TLS_CERT} / {TLS_KEY}; '
        f'starting cleartext only\n')


_PROCS = (http_proc, h2c_proc, https_h1_proc, https_h2_proc)


def _shutdown(*_):
    for p in _PROCS:
        if p is not None:
            p.terminate()
    time.sleep(1)
    for p in _PROCS:
        if p is not None and p.poll() is None:
            p.kill()
    sys.exit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT,  _shutdown)

try:
    rc = http_proc.wait()
finally:
    for p in (h2c_proc, https_h1_proc, https_h2_proc):
        if p is not None:
            p.terminate()
sys.exit(rc)
