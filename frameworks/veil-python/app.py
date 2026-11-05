"""HttpArena entry for veil-api (Python).

Handlers are ``@app.get`` / ``@app.post`` functions; ``async def`` handlers run on veil's persistent event loop,
``/ws`` is ``@app.websocket``, gRPC uses the grpcio-generated servicer on ``veil.grpc.Server``, and ``/static`` is
``app.serve_dir``. Listeners, TLS, compression and logging come from ``veil.toml`` (one process, four listeners).
"""

import asyncio
import json
import os
import sys

import veil
import veil.grpc

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "gen"))

import benchmark_pb2 as pb  # noqa: E402
import benchmark_pb2_grpc  # noqa: E402

try:
    with open("/data/dataset.json") as f:
        DATASET = json.load(f)
except OSError:
    DATASET = []

app = veil.App(title="httparena")


@app.get("/baseline11", offload=False)
def baseline11_get(a: int, b: int):
    return str(a + b)


@app.post("/baseline11", offload=False)
def baseline11_post(request: veil.Request, a: int, b: int):
    try:
        n = int(request.body.strip() or 0)
    except ValueError:
        n = 0
    return str(a + b + n)


@app.get("/baseline2", offload=False)
def baseline2(a: int, b: int):
    return str(a + b)


@app.get("/pipeline", offload=False)
def pipeline():
    return "ok"


@app.get("/json/{count}")
def json_items(count: int, m: int = 1):
    items = [dict(item, total=item["price"] * item["quantity"] * m) for item in DATASET[:count]]
    return {"items": items, "count": len(items)}


@app.get("/delay/{ms}")
async def delay(ms: int):
    await asyncio.sleep(min(ms, 60000) / 1000)
    return str(ms)


@app.post("/echo")
def echo(request: veil.Request):
    return veil.Response(request.body, media_type="application/octet-stream")


@app.websocket("/ws")
async def ws(websocket: veil.WebSocket):
    await websocket.accept()
    while True:
        m = await websocket.receive()
        if m["type"] == "websocket.disconnect":
            return
        if m.get("text") is not None:
            await websocket.send_text(m["text"])
        else:
            await websocket.send_bytes(m["bytes"])


class Benchmark(benchmark_pb2_grpc.BenchmarkServiceServicer):
    def GetSum(self, request, context):
        return pb.SumReply(result=request.a + request.b)

    def StreamSum(self, request, context):
        reply = pb.SumReply(result=request.a + request.b)
        for _ in range(max(0, min(request.count, 1000000))):
            yield reply

    def CollectSum(self, request_iterator, context):
        return pb.SumReply(result=sum(r.a + r.b for r in request_iterator))

    def EchoSum(self, request_iterator, context):
        for r in request_iterator:
            yield pb.SumReply(result=r.a + r.b)


app.serve_dir("/static", "/data/static", compression={"enabled": True})

server = veil.grpc.Server(app)
benchmark_pb2_grpc.add_BenchmarkServiceServicer_to_server(Benchmark(), server)

if __name__ == "__main__":
    app.run(config_path=os.environ.get("VEIL_CONFIG", os.path.join(HERE, "veil.toml")))
