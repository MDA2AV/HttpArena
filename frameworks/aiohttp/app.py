import asyncio
import json
import os
import signal

import uvloop
from aiohttp import web

PORT = 8080
BACKLOG = 4096
MAX_BODY = 64 * 1024 * 1024

DATASET_PATH = os.environ.get("DATASET_PATH", "/data/dataset.json")
DATASET = []
try:
    with open(DATASET_PATH) as dataset_file:
        DATASET = json.load(dataset_file)
except Exception:
    DATASET = []


def cpu_count():
    # cgroup quota first, so the worker count follows the container limit
    # and not the host. Falls back to the CPU affinity mask, which is what
    # --cpuset-cpus restricts.
    try:
        with open("/sys/fs/cgroup/cpu.max") as cpu_max:
            quota, period = cpu_max.read().split()
        if quota != "max":
            limit = int(quota) // int(period)
            if limit >= 1:
                return limit
    except Exception:
        pass
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


async def pipeline(request):
    return web.Response(body=b"ok", content_type="text/plain")


async def baseline11(request):
    total = 0
    for value in request.query.values():
        try:
            total += int(value)
        except ValueError:
            pass
    if request.method == "POST":
        try:
            total += int((await request.text()).strip())
        except ValueError:
            pass
    return web.Response(body=str(total).encode(), content_type="text/plain")


async def json_items(request):
    try:
        count = int(request.match_info["count"])
    except ValueError:
        count = 0
    if count < 0:
        count = 0
    elif count > len(DATASET):
        count = len(DATASET)
    try:
        m = int(request.query.get("m", 1))
    except ValueError:
        m = 1
    items = []
    for item in DATASET[:count]:
        processed = dict(item)
        processed["total"] = item["price"] * item["quantity"] * m
        items.append(processed)
    response = web.json_response({"items": items, "count": count})
    # standard mode: gzip comes from aiohttp's own response compression, which
    # picks the coding from Accept-Encoding and stays off when the header is absent
    response.enable_compression()
    return response


async def upload(request):
    size = 0
    async for chunk in request.content.iter_any():
        size += len(chunk)
    return web.Response(body=str(size).encode(), content_type="text/plain")


def build_app():
    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_get("/pipeline", pipeline)
    app.router.add_get("/baseline11", baseline11)
    app.router.add_post("/baseline11", baseline11)
    app.router.add_get("/json/{count}", json_items)
    app.router.add_post("/upload", upload)
    return app


def serve():
    loop = uvloop.new_event_loop()
    asyncio.set_event_loop(loop)
    runner = web.AppRunner(build_app(), access_log=None)
    loop.run_until_complete(runner.setup())
    site = web.TCPSite(
        runner, "0.0.0.0", PORT,
        reuse_port=True, backlog=BACKLOG, shutdown_timeout=1.0,
    )
    loop.run_until_complete(site.start())
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, loop.stop)
    try:
        loop.run_forever()
    finally:
        loop.run_until_complete(runner.cleanup())


def main():
    # aiohttp runs one event loop on one thread, so multi-core means one
    # process per core. Each worker opens its own SO_REUSEPORT listener and
    # the kernel spreads the connections.
    workers = cpu_count()
    if workers <= 1:
        serve()
        return

    children = []
    for _ in range(workers):
        pid = os.fork()
        if pid == 0:
            serve()
            os._exit(0)
        children.append(pid)

    def stop(signum, frame):
        for pid in children:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    for pid in children:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


if __name__ == "__main__":
    main()
