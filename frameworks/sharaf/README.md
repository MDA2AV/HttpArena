# Sharaf

Sharaf uses one virtual thread per persistent connection. PostgreSQL-backed
profiles use Squery and HikariCP.

Supported profiles:

- `baseline`, `pipelined`, `limited-conn`
- `async`
- `json-comp`
- `async-db`, `fortunes`
- `latency-1m`, `latency-10k`, `latency-500k-8cpu`

Potateh does not currently provide TLS, HTTP/2, HTTP/3, WebSocket, or gRPC, so
those profiles are intentionally not advertised.

```bash
./scripts/validate.sh sharaf
./scripts/benchmark-lite.sh sharaf baseline,pipelined,limited-conn
```
