"""HttpArena core server for mq-bridge-py (Python).

Serves the cleartext HTTP/1.1 + HTTP/2 (h2c) profiles on ``0.0.0.0:8080`` via a
single catch-all ``http -> response`` route. mq-bridge keeps all HTTP framing in
Rust (hyper-util's auto connection builder negotiates HTTP/1.1 and h2 prior
knowledge on the plaintext port), and the inline-response fast path keeps the
response on the Rust side; the Python handler runs only the per-request dispatch.

Endpoints (HttpArena reference contract)
----------------------------------------
* ``GET  /pipeline``                    -> ``ok``             (baseline/pipelined/limited-conn)
* ``GET  /baseline11?a=&b=``            -> ``a+b``            (baseline)
* ``POST /baseline11?a=&b=`` + body int -> ``a+b+body``
* ``GET  /baseline2?a=&b=``             -> ``a+b``
* ``GET  /json/{count}?m=``             -> processed dataset JSON  (json/json-comp)
* ``POST /upload`` + body               -> received byte count     (upload)
* ``GET  /async-db?min=&max=&limit=``   -> Postgres ``items`` rows  (async-db)
* ``GET  /static/{file}``               -> file from /data/static   (static)

Harness inputs: dataset from ``/data/dataset.json`` (``DATASET_PATH`` overrides),
static assets from ``/data/static`` (``STATIC_DIR``), Postgres from
``DATABASE_URL``. A missing DB / driver is non-fatal: ``/async-db`` then returns
an empty result so the cleartext profiles still run.

``json-comp`` is handled by mq-bridge's response compression
(``compression_enabled``): bodies over the threshold are gzip-encoded when the
client advertises ``Accept-Encoding: gzip``, identity otherwise — so the same
``/json`` handler serves both ``json`` and ``json-comp``.
"""

from __future__ import annotations

import gzip as _gzip
import json as _json
import os
import signal
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs

from mq_bridge import Message, Route

LISTEN = os.environ.get("MQB_LISTEN", "0.0.0.0:8080")
H2C_LISTEN = os.environ.get("MQB_H2C_LISTEN", "0.0.0.0:8082")
TLS_LISTEN = os.environ.get("MQB_TLS_LISTEN", "0.0.0.0:8443")
H1TLS_LISTEN = os.environ.get("MQB_H1TLS_LISTEN", "0.0.0.0:8081")
TLS_CERT = os.environ.get("TLS_CERT", "/certs/server.crt")
TLS_KEY = os.environ.get("TLS_KEY", "/certs/server.key")
DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
STATIC_DIR = Path(os.environ.get("STATIC_DIR", "/data/static")).resolve()

SERVER = "mq-bridge-py"
JSON_META = {"content-type": "application/json", "Server": SERVER}
TEXT_META = {"content-type": "text/plain; charset=utf-8", "Server": SERVER}
NOT_FOUND_META = {
    "content-type": "text/plain; charset=utf-8",
    "Server": SERVER,
    "http_status_code": "404",
}

def _tls_available() -> bool:
    return Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()


def _http_route(name: str, listen: str, http_workers: int, extra: str = "") -> str:
    return f"""
  {name}:
    concurrency: 1
    batch_size: 1024
    input:
      http:
        url: "{listen}"
        workers: {http_workers}
        concurrency_limit: 65536
        internal_buffer_size: 16384
        inline_response_fast_path: true
        compression_enabled: true
        compression_threshold_bytes: 256
{extra}
    output:
      response: {{}}
"""


def _config(http_workers: int) -> tuple[str, list[str]]:
    # `http_workers` is the number of accept loops (each its own SO_REUSEPORT
    # listener) inside this process. When we fan out across processes we keep
    # this small (the single Python worker is the per-process bottleneck); in
    # single-process mode we use all cores, matching the previous default.
    names = ["httparena"]
    routes = [_http_route(names[0], LISTEN, http_workers)]

    # HTTP/2 cleartext (prior-knowledge) on 8082 (baseline-h2c / json-h2c), using
    # the same handlers as the plaintext listener. `http2_only` makes the port
    # refuse HTTP/1.1, satisfying the h2c-only anti-cheat (a dual-serving port is
    # rejected). Cleartext, so no certs are needed.
    names.append("httparena-h2c")
    routes.append(
        _http_route(
            names[-1],
            H2C_LISTEN,
            http_workers,
            "        server_protocol: http2_only",
        )
    )

    # TLS listeners, only when the harness has mounted certs — a local
    # plaintext-only run still works.
    if _tls_available():
        tls_block = (
            f'        tls:\n'
            f'          required: true\n'
            f'          cert_file: "{TLS_CERT}"\n'
            f'          key_file: "{TLS_KEY}"'
        )
        # HTTP/2 over TLS on 8443 (baseline-h2 / static-h2): ALPN advertises `h2`.
        names.append("httparena-tls")
        routes.append(_http_route(names[-1], TLS_LISTEN, http_workers, tls_block))
        # JSON over HTTP/1.1 + TLS on 8081 (json-tls): the same `/json` handler,
        # but the port advertises ALPN `http/1.1` only so the wrk load generator
        # negotiates HTTP/1.1 rather than upgrading to h2.
        names.append("httparena-json-tls")
        routes.append(
            _http_route(
                names[-1],
                H1TLS_LISTEN,
                http_workers,
                tls_block + "\n        server_protocol: http1_only",
            )
        )

    return "routes:\n" + "\n".join(routes), names


# Static assets are pre-gzipped once at startup (see CachedBody) and the reply
# carries `content-encoding: gzip` when the client accepts it — mq-bridge honors
# that and skips re-compressing them per request. Dynamic `/json` responses are
# serialized fresh per request (no response caching) and compressed by the
# library's per-request gzip when the client advertises Accept-Encoding.

CONTENT_TYPES = {
    "js": "application/javascript",
    "css": "text/css",
    "html": "text/html",
    "json": "application/json",
    "woff2": "font/woff2",
    "png": "image/png",
    "svg": "image/svg+xml",
}


class CachedBody:
    """A response body cached in both identity and gzip form, with pre-built
    reply metadata for each. Lets a hot endpoint serve a request with a dict
    lookup and zero per-request serialization, gzip, or metadata allocation.
    The gzip variant is only kept when it actually shrinks the body."""

    __slots__ = ("plain", "gzip", "_meta_plain", "_meta_gzip")

    def __init__(self, body: bytes, content_type: str):
        self.plain = body
        self._meta_plain = {"content-type": content_type, "Server": SERVER}
        # mtime=0 keeps the gzip bytes deterministic across processes/restarts.
        compressed = _gzip.compress(body, compresslevel=6, mtime=0)
        if len(compressed) < len(body):
            self.gzip = compressed
            self._meta_gzip = {
                "content-type": content_type,
                "Server": SERVER,
                "content-encoding": "gzip",
            }
        else:
            self.gzip = None
            self._meta_gzip = None

    def message(self, request: "Message", want_gzip: bool) -> "Message":
        if want_gzip and self.gzip is not None:
            return request.__class__(self.gzip, self._meta_gzip)
        return request.__class__(self.plain, self._meta_plain)


def _load_dataset() -> list[dict]:
    try:
        with open(DATASET_PATH, "rb") as f:
            data = _json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


DATASET = _load_dataset()


# ---------- optional Postgres (async-db) ----------

_POOL = None


def _init_pool():
    url = os.environ.get("DATABASE_URL", "")
    if not url:
        return None
    try:
        from psycopg_pool import ConnectionPool
    except ImportError:
        return None
    max_conn = int(os.environ.get("DATABASE_MAX_CONN", "256"))
    try:
        pool = ConnectionPool(url, min_size=1, max_size=max_conn, open=True)
        return pool
    except Exception as exc:  # noqa: BLE001 - non-fatal, /async-db degrades to empty
        print(f"Postgres connection failed ({exc}); /async-db returns empty")
        return None


def _query_int(qs: dict[str, list[str]], key: str, default: int) -> int:
    try:
        return int(qs[key][0])
    except (KeyError, IndexError, ValueError):
        return default


# ---------- handlers ----------

def _build_json(count: int, m: int) -> bytes:
    count = min(count, len(DATASET))
    items = []
    for d in DATASET[:count]:
        items.append(
            {
                "id": d["id"],
                "name": d["name"],
                "category": d["category"],
                "price": d["price"],
                "quantity": d["quantity"],
                "active": d["active"],
                "tags": d["tags"],
                "rating": {"score": d["rating"]["score"], "count": d["rating"]["count"]},
                "total": d["price"] * d["quantity"] * m,
            }
        )
    return _json.dumps({"items": items, "count": count}, separators=(",", ":")).encode()


def _async_db(qs: dict[str, list[str]]) -> bytes:
    if _POOL is None:
        return b'{"items":[],"count":0}'
    min_p = _query_int(qs, "min", 10)
    max_p = _query_int(qs, "max", 50)
    limit = max(1, min(_query_int(qs, "limit", 50), 50))
    try:
        with _POOL.connection() as conn:
            cur = conn.execute(
                "SELECT id, name, category, price, quantity, active, tags, "
                "rating_score, rating_count FROM items WHERE price BETWEEN %s AND %s LIMIT %s",
                (min_p, max_p, limit),
            )
            rows = cur.fetchall()
    except Exception:  # noqa: BLE001 - degrade to empty result
        return b'{"items":[],"count":0}'
    items = [
        {
            "id": r[0],
            "name": r[1],
            "category": r[2],
            "price": r[3],
            "quantity": r[4],
            "active": r[5],
            "tags": r[6],
            "rating": {"score": r[7], "count": r[8]},
        }
        for r in rows
    ]
    return _json.dumps({"count": len(items), "items": items}, separators=(",", ":")).encode()


def _content_type_for(name: str) -> str:
    ext = name.rsplit(".", 1)[-1] if "." in name else ""
    return CONTENT_TYPES.get(ext, "application/octet-stream")


def _reply(request: Message, body: bytes, metadata: dict[str, str]) -> Message:
    return request.__class__(body, metadata)


def _accepts_gzip(message: Message) -> bool:
    header = message.metadata.get("accept-encoding", "").lower()
    for directive in header.split(","):
        token, _, params = directive.strip().partition(";")
        if token != "gzip":
            continue
        # Honour an explicit q-value: q=0 means "not acceptable".
        for param in params.split(";"):
            key, _, value = param.strip().partition("=")
            if key == "q":
                try:
                    return float(value) > 0
                except ValueError:
                    return False
        return True
    return False


def _load_static_cache() -> dict[str, CachedBody]:
    # Read and pre-gzip every static asset once at startup so each request is a
    # dict lookup with no filesystem I/O or per-request allocation. Built at
    # import (before fork), so worker processes share it copy-on-write.
    cache: dict[str, CachedBody] = {}
    try:
        entries = list(STATIC_DIR.iterdir())
    except OSError:
        return cache
    for entry in entries:
        try:
            if entry.is_file():
                cache[entry.name] = CachedBody(
                    entry.read_bytes(), _content_type_for(entry.name)
                )
        except OSError:
            continue
    return cache


STATIC_CACHE = _load_static_cache()


def _serve_static(request: Message, name: str, want_gzip: bool) -> Message:
    # Reject path traversal: the name must be a single normal path component.
    # (The cache is keyed by bare filename, so traversal can't hit an entry, but
    # keep the explicit guard for clarity.)
    if not name or "/" in name or name in (".", ".."):
        return _reply(request, b"Not Found", NOT_FOUND_META)
    cached = STATIC_CACHE.get(name)
    if cached is None:
        return _reply(request, b"Not Found", NOT_FOUND_META)
    return cached.message(request, want_gzip)


def handle(message: Message) -> Message:
    method = message.metadata.get("http_method", "")
    path = message.metadata.get("http_path", "")
    qs = parse_qs(message.metadata.get("http_query", ""))

    if method == "GET" and path == "/pipeline":
        return _reply(message, b"ok", TEXT_META)
    if method == "GET" and path in ("/baseline11", "/baseline2"):
        total = _query_int(qs, "a", 0) + _query_int(qs, "b", 0)
        return _reply(message, str(total).encode(), TEXT_META)
    if method == "POST" and path == "/baseline11":
        total = _query_int(qs, "a", 0) + _query_int(qs, "b", 0)
        try:
            total += int(bytes(message.payload).decode().strip())
        except (ValueError, UnicodeDecodeError):
            pass
        return _reply(message, str(total).encode(), TEXT_META)
    if method == "POST" and path == "/upload":
        return _reply(message, str(len(message.payload)).encode(), TEXT_META)
    if method == "GET" and path == "/async-db":
        return _reply(message, _async_db(qs), JSON_META)
    if method == "GET" and path.startswith("/json/"):
        try:
            count = int(path[len("/json/"):])
        except ValueError:
            count = 0
        return _reply(message, _build_json(count, _query_int(qs, "m", 1)), JSON_META)
    if method == "GET" and path.startswith("/static/"):
        return _serve_static(message, path[len("/static/"):], _accepts_gzip(message))
    return _reply(message, b"Not Found", NOT_FOUND_META)


def _run_secondary_listener(route: Route) -> None:
    try:
        route.run()
    finally:
        os.kill(os.getpid(), signal.SIGTERM)


def _run_worker(http_workers: int) -> None:
    # Per-process setup: the Postgres pool (background threads) and the Rust
    # runtime must be created AFTER any fork, never inherited across it.
    global _POOL
    _POOL = _init_pool()
    config, names = _config(http_workers)
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(config)
        config_path = f.name

    routes = [Route.from_yaml(config_path, name).with_handler(handle) for name in names]
    # Keep every port fail-fast: if any secondary listener exits, signal this
    # worker so the parent supervisor restarts a clean set instead of leaving a
    # partially serving process behind.
    for route in routes[1:]:
        threading.Thread(
            target=_run_secondary_listener,
            args=(route,),
            daemon=False,
        ).start()
    routes[0].run()


def _worker_count() -> int:
    # One Python worker per process is the per-core ceiling (one GIL each), so
    # we scale across cores with OS processes co-binding the same SO_REUSEPORT
    # port. MQB_WORKERS overrides; <=0 means "all cores".
    try:
        n = int(os.environ.get("MQB_WORKERS", "0"))
    except ValueError:
        n = 0
    return n if n > 0 else (os.cpu_count() or 1)


def _set_pdeathsig() -> None:
    # Linux best-effort: have the kernel kill this child if the supervisor dies,
    # so workers are never orphaned. No-op elsewhere.
    try:
        import ctypes

        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL)
    except Exception:  # noqa: BLE001 - purely advisory
        pass


def main() -> None:
    workers = _worker_count()
    if workers <= 1 or not hasattr(os, "fork"):
        # Single process: use all cores for HTTP accept loops (prior default).
        _run_worker(os.cpu_count() or 1)
        return

    # Fan out one serving process per core. Fork BEFORE creating the pool / Rust
    # runtime so each child starts single-threaded (forking a multi-threaded
    # process is unsafe). Each process keeps a small number of accept loops and
    # SO_REUSEPORT balances connections across all of them. The parent stays a
    # dedicated supervisor: it never calls route.run(), so its Python signal
    # handler is not clobbered by the Rust runtime's own signal handling.
    per_proc_http_workers = 2
    children: list[int] = []
    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            _set_pdeathsig()
            _run_worker(per_proc_http_workers)  # never returns
            os._exit(0)
        children.append(pid)

    def _shutdown(_signum=None, _frame=None):
        for pid in children:
            try:
                os.kill(pid, signal.SIGTERM)  # workers exit gracefully on TERM
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5.0
        for pid in children:
            while True:
                try:
                    done, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    break
                if done or time.monotonic() > deadline:
                    break
                time.sleep(0.05)
        for pid in children:  # escalate to anything still standing
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    # Block here; if any worker dies unexpectedly, tear the whole group down so
    # the orchestrator restarts a clean set rather than a degraded one.
    try:
        os.wait()
    except ChildProcessError:
        pass
    _shutdown()


if __name__ == "__main__":
    main()
