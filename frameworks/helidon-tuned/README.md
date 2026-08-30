Helidon Tuned
----

# Project

This framework runs Helidon SE 4.5.4 on Níma WebServer as a `tuned`
benchmark entry.

The current subscribed benchmark profiles are:

- `baseline`
- `latency-1m`
- `latency-10k`
- `pipelined`
- `limited-conn`
- `json-comp`
- `json-tls`
- `static-tls`
- `8gbit`
- `async-db`
- `baseline-h2`
- `static-h2`
- `baseline-h2c`
- `json-h2c`
- `unary-grpc`
- `unary-grpc-tls`
- `echo-ws`
- `echo-ws-pipeline`
- `echo-ws-limited`

Profiles not currently supported here:

- application profiles: `async`, `fortunes`
- HTTP/3: `baseline-h3`, `static-h3`
- composed deployments: `gateway-64`, `gateway-h3`, `production-stack`

# Listener layout

The benchmark wiring is split by listener:

- `8080` (`default`): HTTP/1.1 endpoints, cleartext gRPC for `unary-grpc`, and WebSocket
- `8081` (`h1-tls`): HTTP/1.1 + TLS for `json-tls`, `static-tls`, and `8gbit`
- `8082` (`h2c`): cleartext prior-knowledge HTTP/2 for `baseline-h2c` and `json-h2c`
- `8443` (`h2-tls`): HTTP/2 + TLS for `baseline-h2`, `static-h2`, and `unary-grpc-tls`

TLS is configured from `application.yaml`. Static content is served
programmatically from `/data/static`, reading from disk on each request while
preferring precompressed `.br` / `.gz` variants and setting
`Vary: Accept-Encoding`.

# Tuned protocol configuration

For the benchmark's fixed valid requests, `application.yaml` disables Helidon's
configurable HTTP/2 request-header, response-header, and path validation. Core
HTTP/2 framing, pseudo-header, and connection-header validation remains
enabled. This benchmark-specific setting applies only to `helidon-tuned`;
`helidon-production` retains the standard validation configuration.

# Divergence from benchmark guidance

## `async-db` uses JDBC + HikariCP

The benchmark guidance for `async-db` prefers an async PostgreSQL driver.
This Helidon entry currently uses the standard PostgreSQL JDBC driver with
HikariCP.

That means the implementation is benchmark-contract correct, but it does not
follow the async-driver recommendation literally. This is an intentional
tradeoff for the current Helidon/Níma tuned entry.

Helidon WebServer is designed for Java Virtual Threads and optimized for blocking operations.
