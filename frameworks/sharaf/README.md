# Sharaf

Sharaf uses one virtual thread per persistent connection. PostgreSQL-backed
profiles use Squery and HikariCP.

Supported profiles:

- `baseline`, `pipelined`, `limited-conn`
- `async`
- `json-comp`, `json-tls`, `static-tls`
- `async-db`, `fortunes`
- `latency-1m`, `latency-10k`, `latency-500k-8cpu`

The TLS listener on port 8081 starts when the PEM certificate and PKCS#8 key are
available at `TLS_CERT` and `TLS_KEY` (defaulting to `/certs/server.crt` and
`/certs/server.key`). Static files are read from `/data/static`. Potateh does
not currently provide HTTP/2, HTTP/3, WebSocket,
or gRPC, so those profiles are not advertised.

```bash
./scripts/validate.sh sharaf
./scripts/benchmark-lite.sh sharaf baseline,pipelined,limited-conn
```
