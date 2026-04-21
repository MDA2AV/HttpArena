# HttpArena

[![Discord](https://discordapp.com/api/guilds/1177529388229734410/widget.png?style=shield)](https://discord.com/invite/H84B5ZqDXR)

HTTP framework benchmark platform.

26 test profiles. 64-core dedicated hardware. Same conditions for every framework.

[View Leaderboard](https://www.http-arena.com/) | [Documentation](https://www.http-arena.com/docs/) | [Add a Framework](https://www.http-arena.com/docs/add-framework/)

---

## PR Commands

Tag **@BennyFranciscus** on your PR for help with implementation or benchmark questions.

| Command | Description |
|---------|-------------|
| `/validate -f <framework>` | Run the 18-point validation suite |
| `/benchmark -f <framework>` | Run all benchmark tests |
| `/benchmark -f <framework> -t <test>` | Run a specific test |
| `/benchmark -f <framework> --save` | Run and save results (updates leaderboard on merge) |
| `/benchmark -f <framework> -t <test> --save` | Run specific test and save results |

Always specify `-f <framework>`. Results are automatically compared against the current leaderboard.

---

## Test Profiles

| Category | Profiles | Description |
|----------|----------|-------------|
| Connection | `baseline`, `pipelined`, `limited-conn` | Mixed GET/POST with query parsing (512/4K conns), 16× batched pipelining, short-lived connections that close after 10 requests |
| Workload | `json`, `json-comp`, `json-tls`, `upload`, `static` | JSON serialization, gzip/brotli compression, HTTP/1.1 over TLS, 20 MB body ingestion, 20-file static asset serving |
| Database | `async-db`, `crud` | Async Postgres sequential scan; realistic REST API with cached reads, list, upsert, update, and optional Redis cache |
| Multi-endpoint | `api-4`, `api-16` | Mixed baseline + JSON + async-db at CPU-budget cliffs (4 and 16 CPUs) |
| H/2 | `baseline-h2`, `static-h2`, `baseline-h2c`, `json-h2c` | Baseline + static over TLS with h2 stream multiplexing; baseline + JSON over cleartext h2 (prior-knowledge, port 8082) |
| H/3 | `baseline-h3`, `static-h3` | Baseline and static over QUIC with TLS 1.3 |
| gRPC | `unary-grpc`, `unary-grpc-tls`, `stream-grpc`, `stream-grpc-tls` | Unary and server-streaming gRPC over plaintext HTTP/2 and TLS |
| Gateway | `gateway-64`, `gateway-h3` | Reverse proxy + server stack over HTTP/2 and HTTP/3 with mixed workload |
| Production Stack | `production-stack` | Four-service architecture: edge + Redis + JWT auth sidecar + server, 10K-item cache-aside, concurrent reads + writes |
| WebSocket | `echo-ws` | WebSocket echo throughput across connection counts |

## Run Locally

```bash
git clone https://github.com/MDA2AV/HttpArena.git
cd HttpArena

./scripts/validate.sh <framework>            # correctness check
./scripts/benchmark.sh <framework>           # all profiles
./scripts/benchmark.sh <framework> baseline  # specific profile
./scripts/benchmark.sh <framework> --save    # save results
```

## Contributing

- [Add a new framework](https://www.http-arena.com/docs/add-framework/)
- Improve an existing implementation — open a PR modifying files under `frameworks/<name>/`
- [Open an issue](https://github.com/MDA2AV/HttpArena/issues)
- Comment on any open issue or PR

### Framework Maintainers

Add your GitHub username to the `maintainers` array in your framework's `meta.json` to get notified when someone opens a PR that touches your framework:

```json
"maintainers": ["your-github-username"]
```
