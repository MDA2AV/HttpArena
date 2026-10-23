from std.os import getenv
from std.pathlib import Path

from json import JsonWriter, loads, Value
from json.reflection import serialize_json_into

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
    ok_json,
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


@fieldwise_init
struct Rating(Copyable, Movable):
    var score: Int
    var count: Int


@fieldwise_init
struct Item(Copyable, Movable):
    var id: Int
    var name: String
    var category: String
    var price: Int
    var quantity: Int
    var active: Bool
    var tags: List[String]
    var rating: Rating
    var total: Int


def _item(v: Value) raises -> Item:
    var tags = List[String]()
    for t in v.get("tags").value().array_items():
        tags.append(t.string_value())
    ref r = v.get("rating").value()
    return Item(
        Int(v.get("id").value().int_value()),
        v.get("name").value().string_value(),
        v.get("category").value().string_value(),
        Int(v.get("price").value().int_value()),
        Int(v.get("quantity").value().int_value()),
        v.get("active").value().bool_value(),
        tags^,
        Rating(
            Int(r.get("score").value().int_value()),
            Int(r.get("count").value().int_value()),
        ),
        0,
    )


def _write_item(mut w: JsonWriter, it: Item, total: Int):
    """``it`` as the object reflection would write, with ``total`` in
    place of its own, straight from the shared item: copying it per
    request to set ``total`` cost an allocation per string."""
    w.write_bytes('{"id":'.as_bytes())
    w.write_int(Int64(it.id))
    w.write_bytes(',"name":'.as_bytes())
    w.write_string(it.name)
    w.write_bytes(',"category":'.as_bytes())
    w.write_string(it.category)
    w.write_bytes(',"price":'.as_bytes())
    w.write_int(Int64(it.price))
    w.write_bytes(',"quantity":'.as_bytes())
    w.write_int(Int64(it.quantity))
    w.write_bytes(',"active":'.as_bytes())
    w.write_bool(it.active)
    w.write_bytes(',"tags":['.as_bytes())
    for j in range(len(it.tags)):
        if j > 0:
            w.write_byte(UInt8(0x2C))
        w.write_string(it.tags[j])
    w.write_bytes('],"rating":{"score":'.as_bytes())
    w.write_int(Int64(it.rating.score))
    w.write_bytes(',"count":'.as_bytes())
    w.write_int(Int64(it.rating.count))
    w.write_bytes('},"total":'.as_bytes())
    w.write_int(Int64(total))
    w.write_byte(UInt8(0x7D))


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
        var w = JsonWriter(capacity=256 * count)
        w.begin_object()
        w.key("items")
        w.begin_array()
        for i in range(count):
            ref it = self.items[i]
            w.next_child(i == 0)
            _write_item(w, it, it.price * it.quantity * m)
        w.end_array()
        w.value_written()
        w.key("count")
        w.write_int(Int64(count))
        w.value_written()
        w.end_object()
        var r = Response(status=200, body=w^.finish())
        r.headers.set("Content-Type", "application/json")
        return r^


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

    def __init__(out self, var values: List[Value]) raises:
        var items = List[Item]()
        for v in values:
            items.append(_item(v))
        self.router = Router()
        self.router.get("/baseline11", baseline)
        self.router.post("/baseline11", baseline)
        self.router.get("/baseline2", baseline)
        self.router.get("/pipeline", pipeline)
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
    var items = loads(f.read()).array_items()
    f.close()
    var app = App(items^)
    var workers = _int(getenv("WORKERS", "1"))
    var mode = getenv("MODE", "plain")
    var port = UInt16(_int(getenv("PORT", "8080")))
    var addr = SocketAddr(IpAddr.parse("0.0.0.0"), port)

    if mode == "tls":
        var alpn = List[String]()
        alpn.append("h2")
        alpn.append("http/1.1")
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
        cfg.max_keepalive_requests = _int(getenv("MAX_KEEPALIVE", "100"))
        cfg.ws = WsUpgrade.on_reactor(WsEcho())
        var srv = HttpServer.bind(addr, cfg^)
        srv.serve(app^, num_workers=workers, pin_cores=False)
