"""HttpArena entry for socketify.py (uWebSockets bindings)."""

import gzip
import json
import os
import sys

from socketify import App, AppOptions

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
TLS_CERT = "/certs/server.crt"
TLS_KEY = "/certs/server.key"
PLAIN_PORT = 8080
TLS_PORT = 8081


def load_dataset():
    """Read once per worker at startup. A missing or broken file is not fatal:
    /json then answers with an empty list."""
    try:
        with open(DATASET_PATH, "rb") as fh:
            return json.load(fh)
    except Exception:
        return []


DATASET = load_dataset()


def parse_int(text):
    try:
        return int(str(text).strip())
    except (TypeError, ValueError):
        return None


def sum_query(queries):
    """Sum of every query parameter whose value parses as an integer; a
    non-numeric one is skipped rather than failing the request."""
    total = 0
    if not queries:
        return total
    for value in queries.values():
        n = parse_int(value[0] if isinstance(value, (list, tuple)) else value)
        if n is not None:
            total += n
    return total


def build_json(count, m):
    n = max(0, min(count, len(DATASET)))
    items = []
    for d in DATASET[:n]:
        items.append({
            "id": d["id"],
            "name": d["name"],
            "category": d["category"],
            "price": d["price"],
            "quantity": d["quantity"],
            "active": d["active"],
            "tags": d["tags"],
            "rating": d["rating"],
            "total": d["price"] * d["quantity"] * m,
        })
    return json.dumps({"items": items, "count": n}).encode()


async def baseline11(res, req):
    # Read before any await: socketify recycles the request object once the
    # handler yields, so anything needed from it must be pulled out first.
    total = sum_query(req.get_queries())
    is_post = req.get_method() == "POST"
    if is_post:
        data = await res.get_data()
        n = parse_int(data.getvalue().decode("utf-8", "replace"))
        if n is not None:
            total += n
    res.write_header("Content-Type", "text/plain")
    res.end(str(total))


def json_items(res, req):
    count = parse_int(req.get_parameter(0)) or 0
    m = parse_int(req.get_query("m"))
    body = build_json(count, 1 if m is None else m)

    # socketify has no response compression of its own, so json-comp is
    # negotiated by hand and encoded at level 1, the level the profile asks for.
    accept = req.get_header("accept-encoding") or ""
    if "gzip" in accept.lower():
        res.write_header("Content-Type", "application/json")
        res.write_header("Content-Encoding", "gzip")
        res.write_header("Vary", "Accept-Encoding")
        res.end(gzip.compress(body, 1))
        return

    res.write_header("Content-Type", "application/json")
    res.end(body)


async def upload(res, req):
    data = await res.get_data()
    res.write_header("Content-Type", "text/plain")
    res.end(str(len(data.getvalue())))


def build_app(options=None):
    app = App(options) if options is not None else App()
    app.get("/baseline11", baseline11)
    app.post("/baseline11", baseline11)
    app.get("/json/:count", json_items)
    app.post("/upload", upload)
    return app


def available_cores():
    """cgroup v2 quota first, then the affinity mask, then the machine size."""
    try:
        with open("/sys/fs/cgroup/cpu.max") as fh:
            quota, period = fh.read().split()
        if quota != "max":
            n = int(quota) // int(period)
            if n >= 1:
                return n
    except Exception:
        pass
    try:
        return len(os.sched_getaffinity(0))
    except Exception:
        return os.cpu_count() or 1


def serve(port, options=None):
    app = build_app(options)
    app.listen(port, lambda _config: None)
    app.run()


def main():
    workers = available_cores()

    # One process per core per port. uWS listens with SO_REUSEPORT, so the
    # children share each port and the kernel balances across them; App.run()
    # blocks, which is also why the TLS listener needs its own processes rather
    # than a second listen on the same app.
    targets = [(PLAIN_PORT, None)]

    # The harness mounts /certs only for the TLS profiles, so a missing pair
    # leaves json-tls unserved rather than aborting startup.
    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        targets.append((TLS_PORT, AppOptions(key_file_name=TLS_KEY, cert_file_name=TLS_CERT)))

    children = []
    for port, options in targets:
        for _ in range(workers):
            pid = os.fork()
            if pid == 0:
                serve(port, options)
                sys.exit(0)
            children.append(pid)

    for pid in children:
        os.waitpid(pid, 0)


if __name__ == "__main__":
    main()
