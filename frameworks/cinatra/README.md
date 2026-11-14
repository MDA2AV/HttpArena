# cinatra

The benchmark service is maintained in cinatra at
[`benchmark/httparena/`](https://github.com/qicosmos/cinatra/tree/d145db352e5aaa779507187440d6358f42e9e19f/benchmark/httparena).
This entry fetches that fixed revision and builds the cases there.

The cases use cinatra's router, request/body APIs, streaming response writer,
builtin gzip, executor-local sleep and WebSocket reader/writer. JSON is selected,
recomputed and serialized per request with bundled iguana. Request-local PMR
vectors borrow immutable dataset strings. The entry is marked tuned for its PMR
storage and native TLS response-buffer setting; compression keeps framework
defaults.

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
