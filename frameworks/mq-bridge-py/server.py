"""HttpArena entry "mq-bridge-py": the mq-bridge Python bindings (PyPI package
``mq-bridge``, imported as ``mq_bridge``).

One catch-all ``http -> response`` route per listener, dispatching on the
request's ``http_method`` / ``http_path`` / ``http_query`` metadata. mq-bridge
keeps all HTTP framing in Rust (hyper-util's auto connection builder negotiates
HTTP/1.1 and h2 prior knowledge on the plaintext port) and the inline-response
fast path keeps the reply on the Rust side, so the Python handler runs only the
per-request dispatch.

===============================  ==========================  =====================
Endpoint                         Reply                       Profiles
===============================  ==========================  =====================
``GET  /pipeline``               ``ok``                      baseline, pipelined,
                                                             limited-conn
``GET  /baseline11?a=&b=``       ``a+b``                     baseline
``POST /baseline11?a=&b=``+body  ``a+b+body``                baseline
``GET  /baseline2?a=&b=``        ``a+b``                     baseline-h2, -h2c
``GET  /json/{count}?m=``        processed dataset           json-comp, json-tls,
                                                             json-h2c
``POST /echo`` + body            the body, unchanged         8gbit
``GET  /delay/{ms}``             ``{ms}`` after waiting      async
``GET  /async-db?min=&max=&limit=``  ``items`` rows          async-db
``GET  /fortunes``               rendered HTML table         fortunes
``GET  /static/{file}``          file from /data/static      static-tls, static-h2
===============================  ==========================  =====================

Listeners: 8080 HTTP/1.1 + h2c (auto), 8082 h2c-only, 8443 h2-over-TLS, 8081
HTTP/1.1-over-TLS. The TLS ports bind only when certs are mounted.

Harness inputs: ``DATASET_PATH``, ``STATIC_DIR``, ``DATABASE_URL``,
``DATABASE_MAX_CONN``. A missing database is non-fatal — the
DB-backed endpoints degrade rather than blocking the cleartext profiles.

``json-comp`` is served by mq-bridge's own response compression
(``compression_enabled``): bodies over the threshold are encoded per request
from the client's ``Accept-Encoding``, identity otherwise.
"""

from __future__ import annotations

import json as _json
import os
import signal
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
TEMPLATE_DIR = Path(os.environ.get("TEMPLATE_DIR", Path(__file__).parent / "templates"))

SERVER = "mq-bridge-py"
JSON_META = {"content-type": "application/json", "Server": SERVER}
TEXT_META = {"content-type": "text/plain; charset=utf-8", "Server": SERVER}
HTML_META = {"content-type": "text/html; charset=utf-8", "Server": SERVER}
OCTET_META = {"content-type": "application/octet-stream", "Server": SERVER}


def _status(code: int, reason: bytes) -> tuple[bytes, dict]:
    return reason, dict(TEXT_META, http_status_code=str(code))


NOT_FOUND = _status(404, b"Not Found")
SERVER_ERROR = _status(500, b"Internal Server Error")
UNAVAILABLE = _status(503, b"Service Unavailable")


# ---------- route configuration ----------

def _tls_available() -> bool:
    return Path(TLS_CERT).is_file() and Path(TLS_KEY).is_file()


def _http_route(listen: str, http_workers: int, **extra) -> dict:
    http = {
        "url": listen,
        "workers": http_workers,
        "concurrency_limit": 65536,
        "internal_buffer_size": 16384,
        "inline_response_fast_path": True,
        "compression_enabled": True,
        "compression_threshold_bytes": 256,
        **extra,
    }
    return {
        "concurrency": 1,
        "batch_size": 1024,
        "input": {"http": http},
        "output": {"response": {}},
    }


def _routes(http_workers: int) -> dict[str, dict]:
    """Route bodies by name. `http_workers` is the number of accept loops (each
    its own SO_REUSEPORT listener) inside this process: small when fanned out
    across processes, all cores in single-process mode."""
    routes = {
        "httparena": _http_route(LISTEN, http_workers),
        # h2c prior knowledge only (baseline-h2c / json-h2c): the port has to
        # refuse HTTP/1.1, a dual-serving one fails the h2c-only anti-cheat.
        "httparena-h2c": _http_route(
            H2C_LISTEN, http_workers, server_protocol="http2_only"
        ),
    }
    # TLS listeners only when the harness has mounted certs, so a local
    # plaintext-only run still works.
    if _tls_available():
        tls = {"required": True, "cert_file": TLS_CERT, "key_file": TLS_KEY}
        # 8443: ALPN `h2` (baseline-h2 / static-h2).
        routes["httparena-tls"] = _http_route(TLS_LISTEN, http_workers, tls=tls)
        # 8081: ALPN `http/1.1` only (json-tls / static-tls), so wrk does not
        # negotiate h2.
        routes["httparena-h1-tls"] = _http_route(
            H1TLS_LISTEN, http_workers, tls=tls, server_protocol="http1_only"
        )
    return routes


# ---------- static ----------
#
# Read from disk on every request. The profile allows serving file contents from
# memory only out of the framework's own static handler; a cache assembled here
# — a startup directory scan, pre-loaded buffers — is explicitly not allowed,
# and the response has to follow the disk. mq-bridge has no static file handler,
# so there is nothing to cache behind and every hit is a real read.
#
# The `.gz` variants ship on disk beside the originals, so picking one off
# Accept-Encoding is a file read rather than compression, which is the one
# entry-side choice the profile permits. Everything else is left to mq-bridge's
# own per-request compression — as `/json` is, serialized fresh and compressed
# by the library when the client advertises an encoding.

CONTENT_TYPES = {
    "js": "application/javascript",
    "css": "text/css",
    "html": "text/html",
    "json": "application/json",
    "woff2": "font/woff2",
    "png": "image/png",
    "svg": "image/svg+xml",
}


def _content_type_for(name: str) -> str:
    ext = name.rsplit(".", 1)[-1] if "." in name else ""
    return CONTENT_TYPES.get(ext, "application/octet-stream")


def _serve_static(name: str, want_gzip: bool) -> tuple[bytes, dict]:
    # Reject traversal: the name must be a single normal path component.
    if not name or "/" in name or name in (".", ".."):
        return NOT_FOUND
    meta = {"content-type": _content_type_for(name), "Server": SERVER}
    if want_gzip:
        try:
            body = (STATIC_DIR / (name + ".gz")).read_bytes()
            return body, dict(meta, **{"content-encoding": "gzip"})
        except OSError:
            pass  # no pre-compressed variant; fall through to the original
    try:
        return (STATIC_DIR / name).read_bytes(), meta
    except OSError:
        return NOT_FOUND


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


# ---------- dataset (json profile) ----------

def _load_dataset() -> list[dict]:
    try:
        with open(DATASET_PATH, "rb") as f:
            data = _json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


DATASET = _load_dataset()


def _query_int(qs: dict[str, list[str]], key: str, default: int) -> int:
    try:
        return int(qs[key][0])
    except (KeyError, IndexError, ValueError):
        return default


def _dumps(obj) -> bytes:
    return _json.dumps(obj, separators=(",", ":")).encode()


def _build_json(qs: dict[str, list[str]], count: int) -> tuple[bytes, dict]:
    """Serialized fresh per request — no response caching. mq-bridge compresses
    it per request when the client advertises an encoding, so `json` and
    `json-comp` both measure real serialization and compression work."""
    m = _query_int(qs, "m", 1)
    count = min(count, len(DATASET))
    items = [
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
        for d in DATASET[:count]
    ]
    return _dumps({"items": items, "count": count}), JSON_META


# ---------- database ----------

_POOL = None

ITEM_COLUMNS = (
    "id, name, category, price, quantity, active, tags, rating_score, rating_count"
)


class _DbError(Exception):
    """Raised by `_fetch`; `handle` maps `.code` to the matching status reply.
    503 means the pool is absent, 500 that the query itself failed."""

    def __init__(self, code: int):
        self.code = code


def _init_pool():
    url = os.environ.get("DATABASE_URL", "")
    if not url:
        return None
    try:
        from psycopg_pool import ConnectionPool
    except ImportError:
        return None
    budget = int(os.environ.get("DATABASE_MAX_CONN", "256"))
    # One pool per forked worker, so the budget is divided by the worker count
    # rather than handed to each. Postgres runs with max_connections=256 and
    # reserves a few of those for the superuser.
    max_conn = max(1, (budget - 8) // max(1, _worker_count()))
    try:
        return ConnectionPool(url, min_size=1, max_size=max_conn, open=True)
    except Exception as exc:  # noqa: BLE001 - non-fatal, DB endpoints degrade
        print(f"Postgres connection failed ({exc}); DB endpoints degrade")
        return None


def _fetch(sql: str, params: tuple = (), one: bool = False):
    """Run one query on the pool. Returns the rows (or the single row, which is
    None when nothing matched); raises `_DbError` when the pool is missing or
    the query fails, so callers never confuse "no such row" with "no database"."""
    if _POOL is None:
        raise _DbError(503)
    try:
        with _POOL.connection() as conn:
            cur = conn.execute(sql, params)
            return cur.fetchone() if one else cur.fetchall()
    except Exception:  # noqa: BLE001
        raise _DbError(500) from None


def _item_row(r) -> dict:
    tags = r[6]
    return {
        "id": r[0],
        "name": r[1],
        "category": r[2],
        "price": r[3],
        "quantity": r[4],
        "active": r[5],
        # tags is a JSONB column, so it arrives as text unless a codec is set
        "tags": _json.loads(tags) if isinstance(tags, str) else tags,
        "rating": {"score": r[7], "count": r[8]},
    }


def _async_db(qs: dict[str, list[str]]) -> tuple[bytes, dict]:
    """A missing database is not an error here: the profile's other listeners
    have to keep serving, so an unreachable pool degrades to an empty result."""
    try:
        rows = _fetch(
            f"SELECT {ITEM_COLUMNS} FROM items WHERE price BETWEEN %s AND %s LIMIT %s",
            (
                _query_int(qs, "min", 10),
                _query_int(qs, "max", 50),
                max(1, min(_query_int(qs, "limit", 50), 50)),
            ),
        )
    except _DbError:
        return b'{"items":[],"count":0}', JSON_META
    items = [_item_row(r) for r in rows]
    return _dumps({"count": len(items), "items": items}), JSON_META


# ---------- fortunes ----------

RUNTIME_FORTUNE = (0, "Additional fortune added at request time.")


def _load_fortunes_template():
    """Jinja2 with autoescape on, loaded from `templates/fortunes.html`. The
    profile's standard rules require a real engine and a template kept as its
    own artifact, so the page is rendered — never concatenated — per request.
    Compiled at import, before the fork, so workers share it copy-on-write."""
    try:
        from jinja2 import Environment, FileSystemLoader, select_autoescape
    except ImportError:
        return None
    env = Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        autoescape=select_autoescape(["html"]),
    )
    try:
        return env.get_template("fortunes.html")
    except Exception:  # noqa: BLE001 - /fortunes then reports unavailable
        return None


FORTUNES_TEMPLATE = _load_fortunes_template()


def _fortunes() -> tuple[bytes, dict]:
    """Query, append the runtime row in memory, sort by ordinal byte order
    (never locale-aware — that reorders per runtime), then render per request."""
    if FORTUNES_TEMPLATE is None:
        return UNAVAILABLE
    rows = list(_fetch("SELECT id, message FROM fortune"))
    rows.append(RUNTIME_FORTUNE)
    # Python compares str by code point, which is the same ordering as UTF-8
    # byte order, so this is the ordinal sort the profile asks for.
    rows.sort(key=lambda r: r[1])
    return FORTUNES_TEMPLATE.render(fortunes=rows).encode(), HTML_META


# ---------- async delay ----------

def _delay(raw: str) -> tuple[bytes, dict]:
    """Blocking sleep, which the profile's standard rules permit explicitly.

    mq-bridge calls the Python handler from a single thread per process, so the
    wait is not overlapped within a worker and concurrency is the process count
    (`MQB_WORKERS`, one per core by default) rather than the connection count.
    That is the cost this profile exists to price; nothing here answers before
    its own delay has elapsed."""
    try:
        ms = int(raw)
    except ValueError:
        return NOT_FOUND
    if ms > 0:
        time.sleep(ms / 1000.0)
    return str(ms).encode(), TEXT_META


# ---------- dispatch ----------

def _baseline(message: Message, qs: dict[str, list[str]]) -> tuple[bytes, dict]:
    total = _query_int(qs, "a", 0) + _query_int(qs, "b", 0)
    if message.metadata.get("http_method") == "POST":
        try:
            total += int(bytes(message.payload).decode().strip())
        except (ValueError, UnicodeDecodeError):
            pass
    return str(total).encode(), TEXT_META


# Exact (method, path) matches. Every handler takes (message, query) and returns
# (body, metadata) so `handle` builds the reply Message in exactly one place.
EXACT_ROUTES = {
    ("GET", "/pipeline"): lambda m, qs: (b"ok", TEXT_META),
    ("GET", "/baseline11"): _baseline,
    ("GET", "/baseline2"): _baseline,
    ("POST", "/baseline11"): _baseline,
    ("POST", "/echo"): lambda m, qs: (m.payload, OCTET_META),
    ("GET", "/async-db"): lambda m, qs: _async_db(qs),
    ("GET", "/fortunes"): lambda m, qs: _fortunes(),
}

# Prefix matches, checked only when no exact route matched. The prefixes are
# disjoint, so order carries no meaning; the tail is passed to the handler.
PREFIX_ROUTES = (
    ("GET", "/json/", lambda m, qs, t: _build_json(qs, _int_or(t, 0))),
    ("GET", "/static/", lambda m, qs, t: _serve_static(t, _accepts_gzip(m))),
    ("GET", "/delay/", lambda m, qs, t: _delay(t)),
)


def _int_or(text: str, default: int) -> int:
    try:
        return int(text)
    except ValueError:
        return default


_DB_ERRORS = {503: UNAVAILABLE, 500: SERVER_ERROR}


def handle(message: Message) -> Message:
    meta = message.metadata
    method = meta.get("http_method", "")
    path = meta.get("http_path", "")
    qs = parse_qs(meta.get("http_query", ""))

    try:
        route = EXACT_ROUTES.get((method, path))
        if route is not None:
            body, reply_meta = route(message, qs)
        else:
            for verb, prefix, fn in PREFIX_ROUTES:
                if method == verb and path.startswith(prefix):
                    body, reply_meta = fn(message, qs, path[len(prefix):])
                    break
            else:
                body, reply_meta = NOT_FOUND
    except _DbError as exc:
        body, reply_meta = _DB_ERRORS[exc.code]

    return Message(body, reply_meta)


# ---------- process model ----------

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
    routes = [
        Route.from_config(body, name).with_handler(handle)
        for name, body in _routes(http_workers).items()
    ]
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
