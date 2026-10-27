# Enso benchmark configuration

This entry uses released Enso 1.0.0-alpha85 with synchronous Ring handlers
on Enso's virtual threads. HTTP/3 uses the matching bundled libquiche shim
for Linux amd64 or arm64, with JVM native access enabled.

The connection limit is 40,000 per listener, rather than Enso's default
10,000: the async profile holds 32,000 connections, and JSON/WebSocket
profiles reach 16,384. The finite limit leaves headroom without disabling
admission control. Execution, QUIC event-loop sizing, timeouts, keep-alive
request limits, buffer budgets, and protocol protections retain Enso defaults.
No custom executors or JVM performance flags are installed.

JSON is serialized and, when negotiated, gzip-compressed on each request.
The entry uses Ring gzip's negotiation and response eligibility helpers,
then JDK `GZIPOutputStream` at its default compression level on the request
virtual thread. Ring's piped gzip wrapper starts a platform-thread future
per response; at 16,384 connections that introduced thousands of threads.
The JSON string is already materialized, so a piped background writer adds
no streaming benefit here. Neither serialized nor compressed JSON is cached.
Static files are served from the mounted directory without caching or
compression.

TLS uses one JDK SSL context loaded from the benchmark's PEM files.
Alpha85 does not have the newer native TCP PEM-loading options, so this
entry supplies the context through its supported API. HTTP/3 uses Enso's
native PEM handling. The optional TCP certificate-rotation/hardening suite
is not claimed; database, gRPC, and gateway application stacks are excluded.

Capacity checks held 32,000 delay connections and 16,384 connections each
for gzip JSON and WebSocket echo, verifying an initial response and three
repeat rounds on every connection. The server was limited to four CPUs and
4 GiB, with a separately limited client. These are capacity/correctness
checks, not throughput measurements or benchmark-platform performance claims.
