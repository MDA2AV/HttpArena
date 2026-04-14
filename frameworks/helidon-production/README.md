Helidon Production
----

# Project

This framework runs Helidon SE 4.4.1 on Níma WebServer as a `production`
benchmark entry.

The current subscribed benchmark profiles are:

- `baseline`
- `pipelined`
- `limited-conn`
- `json`
- `json-comp`
- `json-tls`
- `upload`
- `static`
- `async-db`
- `api-4`
- `api-16`
- `baseline-h2`
- `static-h2`
- `unary-grpc`
- `unary-grpc-tls`
- `stream-grpc`
- `stream-grpc-tls`
- `echo-ws`

Profiles not currently supported here:

- HTTP/3: `baseline-h3`, `static-h3`
- `gateway-64`

# Listener layout

The benchmark wiring is split by listener:

- `8080` (`default`): HTTP/1.1 endpoints, cleartext gRPC for `unary-grpc` and `stream-grpc`, and WebSocket
- `8081` (`h1-tls`): HTTP/1.1 + TLS for `json-tls`
- `8443` (`h2-tls`): HTTP/2 + TLS for `baseline-h2`, `static-h2`, `unary-grpc-tls`, and `stream-grpc-tls`

Static content and TLS are configured from `application.yaml`, not
programmatically.

# Divergence from benchmark guidance

## `async-db` uses JDBC + HikariCP

The benchmark guidance for `async-db` prefers an async PostgreSQL driver.
This Helidon entry currently uses the standard PostgreSQL JDBC driver with
HikariCP.

That means the implementation is benchmark-contract correct, but it does not
follow the async-driver recommendation literally. This is an intentional
tradeoff for the current Helidon/Níma production entry.

Helidon WebServer is designed for Java Virtual Threads and optimized for blocking operations.
