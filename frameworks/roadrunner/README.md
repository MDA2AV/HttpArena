# roadrunner

[Roadrunner](https://github.com/arizona-framework/roadrunner) is the pure-Erlang HTTP/1.1 + HTTP/2 + HTTP/3 + WebSocket server from the Arizona framework. This entry packages a minimal OTP release wrapping roadrunner with the HttpArena endpoint contract.

## Profiles

Covered:

- `baseline`, `pipelined`, `limited-conn`, `async`
- `latency-1m`, `latency-10k`, `latency-500k-8cpu`
- `json-comp`, `json-tls`, `8gbit`, `static-tls`
- `async-db`, `fortunes`
- `baseline-h2`, `static-h2`, `baseline-h2c`, `json-h2c`
- `baseline-h3`, `static-h3`
- `echo-ws`, `echo-ws-pipeline`, `echo-ws-limited`

`gateway-64`, `gateway-h3` and `production-stack` run this same server behind stock proxies, from the compose files in [`frameworks/roadrunner-gateway`](../roadrunner-gateway).

Deferred (tracked under [HttpArena coverage gaps](https://github.com/arizona-framework/roadrunner/blob/main/docs/roadmap.md) in the roadrunner roadmap):

- `unary-grpc` and its TLS variant: no gRPC stack.

## Build

`docker build -t httparena-roadrunner frameworks/roadrunner` then run via `scripts/validate.sh roadrunner` from the repo root.
