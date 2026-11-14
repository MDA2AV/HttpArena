# cinatra

The benchmark service is maintained in cinatra at
[`benchmark/httparena/`](https://github.com/qicosmos/cinatra/tree/2348812dbfd7876bcbc6023d87cf4a2005116f75/benchmark/httparena).
This entry fetches that fixed revision and builds the cases there.

The entry requests `flagship` based on existing downstream use in
[yalantinglibs' coro_http](https://github.com/alibaba/yalantinglibs/blob/54f9c0642386e7860e8e11ada698c484dc562d7d/README.md#standalone-sublibraries)
and [Mooncake's HTTP metadata service](https://github.com/kvcache-ai/Mooncake/blob/504f2ae4a307abe095d3baa75d40ed2661b6481b/mooncake-store/src/http_metadata_server.cpp).
The benchmark configuration remains `tuned`.

The cases use cinatra's router, request/body APIs, streaming response writer,
builtin gzip, executor-local sleep and WebSocket reader/writer. JSON is selected,
recomputed and serialized per request with bundled iguana. Request-local PMR
vectors borrow immutable dataset strings. The entry is marked tuned for its PMR
storage and native contiguous buffers for small baseline replies and TLS
JSON/echo; compression keeps framework defaults.

Responses include Date, Server, Connection and Content-Type; JSON also carries
Vary: Accept-Encoding. Local matched-byte comparisons align these headers, JSON
field order and compression settings across entries and verify raw response
lengths and body hashes before measuring.

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
