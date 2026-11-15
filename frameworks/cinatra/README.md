# cinatra

The benchmark service is maintained in cinatra at
[`benchmark/httparena/`](https://github.com/qicosmos/cinatra/tree/11e9be6c04d204fdadf259a90ec98bb020078ec7/benchmark/httparena).
This entry fetches that fixed revision and builds the cases there.
It explicitly enables `HTTPARENA_X86_64_V3` for the benchmark host. The local
cinatra Dockerfile instead builds the current checkout, with that option off
by default. The benchmark target always enables TLS and gzip, including when
cinatra's top-level SSL option is off.

The entry requests `flagship` based on existing downstream use in
[yalantinglibs' coro_http](https://github.com/alibaba/yalantinglibs/blob/54f9c0642386e7860e8e11ada698c484dc562d7d/README.md#standalone-sublibraries)
and [Mooncake's HTTP metadata service](https://github.com/kvcache-ai/Mooncake/blob/504f2ae4a307abe095d3baa75d40ed2661b6481b/mooncake-store/src/http_metadata_server.cpp).
The benchmark configuration remains `tuned`.

The cases use cinatra's router, request/body APIs, streaming response writer,
builtin gzip, executor-local sleep and WebSocket reader/writer. JSON is selected,
recomputed and serialized per request with bundled iguana. Request-local PMR
vectors borrow immutable dataset strings. The entry is marked tuned for its PMR
storage and native contiguous buffers for small baseline replies and TLS
JSON/echo, plus gzip level 3 through the native response API.

The case keeps automatic Date and disables only Server through cinatra's native
server configuration, including WS/WSS handshakes. It omits extra Connection
headers and uses the same text/JSON Content-Type values and gzip level as dusty.
Date-header byte checks use [dusty's native Date implementation](https://github.com/lalinsky/dusty/commit/ba2236da78ff120618550703e0d2fa59ba78b9ba),
also included in v0.6.0, without adding header overlays. Thirty variants match
complete HTTP lengths (including TLS after decryption), HTTP body hashes,
WS/WSS handshake lengths and TCP/TLS pipelines. The historical dusty v0.5.0
entry omitted Date; its recorded lengths and prior cinatra results describe a
different header configuration.
The service retains native response and WebSocket encoders. Native bounded WebSocket
write batching is enabled; buffered input is drained and pending echoes are
flushed before waiting for more data. Single-message clients do not wait for a
fixed batch size. Buffered headers and payloads bypass the reader-helper
coroutine when no additional input is needed. This revision also includes cinatra's small-input gzip workspace
optimization. Bundled iguana also batches ordinary string writes and generates
fixed JSON field keys at compile time; payload values are still rebuilt and
serialized on every request.

HTTP listens on 8080. When the mounted certificate pair exists, HTTP/1.1 TLS
also listens on 8081. Worker counts follow the container affinity mask.
`CINATRA_THREADS`, `CINATRA_TLS_MULTI_BUFFER`, `DATASET_PATH`, `TLS_CERT` and
`TLS_KEY` are documented with the service.

```sh
./scripts/validate.sh cinatra
./scripts/benchmark.sh cinatra
```

Subscribed profiles: baseline, pipelined, limited-conn, async, latency-10k,
latency-1m, latency-500k-8cpu, json-comp, json-tls, 8gbit and the three WebSocket
echo profiles. Database, template, static-file, HTTP/2, HTTP/3 and gRPC profiles
are not subscribed.
