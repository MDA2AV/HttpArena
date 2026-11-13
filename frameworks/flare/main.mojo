from std.os import getenv
from std.pathlib import Path

from json import deserialize_json

from flare.grpc import GrpcCallContext, GrpcService, GrpcUnary, GrpcUnaryReply
from flare.grpc.proto import ProtoReader, ProtoWriter
from flare.http import (
    Compress,
    FileServer,
    Handler,
    HttpServer,
    Request,
    Response,
    Router,
    ServerConfig,
    WsUpgrade,
    ok,
    ok_json_of,
)
from flare.net import IpAddr, SocketAddr
from flare.quic import QuicServerConfig
from flare.tls import RustlsQuicConfig
from flare.ws.client import WsMessage
from flare.ws.server_reactor import WsReactorHandler, WsSession


def _int(s: String) -> Int:
    try:
        return Int(s)
    except:
        return 0


def _text(body: String) -> Response:
    var r = ok(body)
    try:
        r.headers.set("Content-Type", "text/plain")
    except:
        pass
    return r^


def baseline(req: Request) raises -> Response:
    var sum = _int(req.query_param("a")) + _int(req.query_param("b"))
    if len(req.body) > 0:
        sum += _int(String(StringSlice(unsafe_from_utf8=Span(req.body))))
    return _text(String(sum))


def pipeline(req: Request) raises -> Response:
    return _text("ok")


def echo(req: Request) raises -> Response:
    var r = Response(status=200, body=req.body.copy())
    r.headers.set("Content-Type", "application/octet-stream")
    return r^


@fieldwise_init
struct Rating(Copyable):
    var score: Int
    var count: Int


@fieldwise_init
struct Item(Copyable):
    var id: Int
    var name: String
    var category: String
    var price: Int
    var quantity: Int
    var active: Bool
    var tags: List[String]
    var rating: Rating


@fieldwise_init
struct ItemOut(Copyable):
    var id: Int
    var name: String
    var category: String
    var price: Int
    var quantity: Int
    var active: Bool
    var tags: List[String]
    var rating: Rating
    var total: Int


@fieldwise_init
struct JsonBody(Movable):
    var items: List[ItemOut]
    var count: Int


@fieldwise_init
struct Json(Copyable, Handler):
    var items: List[Item]

    def serve(self, req: Request) raises -> Response:
        var q = req.url.find("?")
        var end = q if q >= 0 else req.url.byte_length()
        var count = _int(String(req.url[byte=6:end]))
        if count < 1 or count > len(self.items):
            return Response(status=400, reason="Bad Request")
        var m = _int(req.query_param("m"))
        var out = List[ItemOut](capacity=count)
        for i in range(count):
            ref it = self.items[i]
            out.append(
                ItemOut(
                    it.id,
                    it.name,
                    it.category,
                    it.price,
                    it.quantity,
                    it.active,
                    it.tags.copy(),
                    it.rating.copy(),
                    it.price * it.quantity * m,
                )
            )
        return ok_json_of(JsonBody(out^, count))


@fieldwise_init
struct GetSum(Copyable, GrpcUnary):
    var unused: Int

    def serve_unary(
        mut self, ctx: GrpcCallContext, request_bytes: Span[UInt8, _]
    ) raises -> GrpcUnaryReply:
        var rd = ProtoReader(request_bytes)
        var a: Int64 = 0
        var b: Int64 = 0
        while rd.has_more():
            var tag = rd.read_tag()
            if tag[0] == 1:
                a = rd.read_int64()
            elif tag[0] == 2:
                b = rd.read_int64()
            else:
                rd.skip(tag[1])
        var w = ProtoWriter()
        w.write_int64(1, a + b)
        return GrpcUnaryReply.ok(w.take())


struct App(Copyable, Handler):
    var router: Router
    var json: Compress[Json]
    var files: FileServer
    var grpc: GrpcService[GetSum]

    def __init__(out self, var items: List[Item]) raises:
        self.router = Router()
        self.router.get("/baseline11", baseline)
        self.router.post("/baseline11", baseline)
        self.router.get("/baseline2", baseline)
        self.router.get("/pipeline", pipeline)
        self.router.post("/echo", echo)
        self.json = Compress(Json(items^), brotli_quality=1, gzip_level=1)
        self.files = FileServer.new("/data")
        self.grpc = GrpcService(GetSum(0))

    def serve(self, req: Request) raises -> Response:
        if req.url.startswith("/json/"):
            return self.json.serve(req)
        if req.url.startswith("/static/"):
            return self.files.serve(req)
        if req.url.startswith("/benchmark.BenchmarkService/"):
            return self.grpc.serve(req)
        return self.router.serve(req)


@fieldwise_init
struct WsEcho(Copyable, WsReactorHandler):
    def on_open(mut self, mut ws: WsSession) raises:
        pass

    def on_message(mut self, mut ws: WsSession, var msg: WsMessage) raises:
        if msg.is_text:
            ws.send_text(msg.as_text())
        else:
            ws.send_binary(msg.as_binary())

    def on_close(mut self, mut ws: WsSession, code: Int):
        pass


def main() raises:
    var f = open(getenv("DATASET", "/data/dataset.json"), "r")
    var items = deserialize_json[List[Item]](f.read())
    f.close()
    var app = App(items^)
    var workers = _int(getenv("WORKERS", "1"))
    var mode = getenv("MODE", "plain")
    var port = UInt16(_int(getenv("PORT", "8080")))
    var addr = SocketAddr(IpAddr.parse("0.0.0.0"), port)

    if mode == "tls":
        var alpn = List[String]()
        for p in getenv("ALPN", "h2,http/1.1").split(","):
            alpn.append(String(p))
        var srv = HttpServer.bind_tls(
            addr, "/certs/server.crt", "/certs/server.key", alpn=alpn^
        )
        srv.serve(app^, num_workers=workers, pin_cores=False)
    elif mode == "h3":
        var tls = RustlsQuicConfig()
        tls.cert_chain_pem = Path("/certs/server.crt").read_text()
        tls.private_key_pem = Path("/certs/server.key").read_text()
        tls.alpn_protocols = List[String]()
        tls.alpn_protocols.append("h3")
        var udp = QuicServerConfig()
        udp.host = "::"
        udp.port = port
        udp.rustls_config = tls^
        udp.num_workers = workers
        var srv = HttpServer.bind_with_http3(
            SocketAddr(IpAddr.localhost(), UInt16(0)), udp^
        )
        srv.serve_http3[App](app^)
    else:
        var cfg = ServerConfig()
        cfg.ws = WsUpgrade.on_reactor(WsEcho())
        var srv = HttpServer.bind(addr, cfg^)
        srv.serve(app^, num_workers=workers, pin_cores=False)
