Helidon Production
----

# Project

This framework runs Helidon SE 27.0.0 on Níma WebServer as a `production`
benchmark entry.

The current subscribed benchmark profiles are:

- `baseline`
- `latency-1m`
- `latency-10k`
- `pipelined`
- `limited-conn`
- `async`
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

- application profiles: `fortunes`
- HTTP/3: `baseline-h3`, `static-h3`
- composed deployments: `gateway-64`, `gateway-h3`, `production-stack`

# Listener layout

The benchmark wiring is split by listener:

- `8080` (`default`): HTTP/1.1 endpoints, cleartext gRPC for `unary-grpc`, and WebSocket
- `8081` (`h1-tls`): HTTP/1.1 + TLS for `json-tls`, `static-tls`, and `8gbit`
- `8082` (`h2c`): cleartext prior-knowledge HTTP/2 for `baseline-h2c` and `json-h2c`
- `8443` (`h2-tls`): HTTP/2 + TLS for `baseline-h2`, `static-h2`, and `unary-grpc-tls`

Static content and TLS are configured from `application.yaml`. Helidon's
static-content feature serves `/data/static` with precompressed `.br` and `.gz`
sidecars, negotiates `Accept-Encoding`, and sets `Vary: Accept-Encoding`.

# Divergence from benchmark guidance

## `async-db` uses JDBC + HikariCP

The benchmark guidance for `async-db` prefers an async PostgreSQL driver.
This Helidon entry currently uses the standard PostgreSQL JDBC driver with
HikariCP.

That means the implementation is benchmark-contract correct, but it does not
follow the async-driver recommendation literally. This is an intentional
tradeoff for the current Helidon/Níma production entry.

## `async` uses virtual threads

Helidon WebServer is designed for Java Virtual Threads and optimized for blocking operations.

The `async` delay handler reads the delay from each `/delay/{ms}` request and
parks Helidon's request virtual thread until a monotonic deadline. It rechecks
that deadline after every wakeup, so an early unpark cannot shorten the delay.
Zero means no intentional wait; negative delays are rejected.

`LockSupport.parkNanos` suspends the virtual thread without occupying its
carrier. This avoids the parking permit that virtual-thread `Thread.sleep`
restores on return in JDK 27, which can cause extra work in the next socket
wait. The handler remains interruptible and sends the response on the original
request thread. No timer executor or response callback is needed.
