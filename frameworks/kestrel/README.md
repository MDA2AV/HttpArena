# kestrel

Kestrel itself, with nothing above it.

There is no routing middleware, no MVC, no minimal-API endpoint mapping and no model binding: a
single `RequestDelegate` reads the path and answers. `aspnet-minimal` measures ASP.NET Core as
people write it; this measures the server underneath, so the distance between the two rows is what
the framework layer costs rather than what Kestrel costs.

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8080 | HTTP/1.1 cleartext | baseline, pipelined, limited-conn, async, latency-1m, latency-10k, json-comp, 8gbit |
| 8082 | HTTP/2 cleartext (prior knowledge) | baseline-h2c, json-h2c |
| 8081 | HTTP/1.1 over TLS | json-tls, static-tls |
| 8443 | HTTP/1.1 + HTTP/2 over TCP, HTTP/3 over QUIC | baseline-h2, static-h2, baseline-h3, static-h3 |

## Notes

- **JSON** responses for the counts and multipliers the profiles ask for are serialized once at
  startup. The workload requests the same shape millions of times, so re-serializing per request
  would measure `System.Text.Json` rather than the server. Anything outside that range still
  serializes on demand.
- **Static files** are read off the mounted directory per request rather than from a copy taken at
  image build, so replacing a file is reflected in the next response. Compression is a precompressed
  `.br`/`.gz` sibling chosen from `Accept-Encoding`, not a compressor in the response path.
- **The delay** uses `Task.Delay`, which registers a timer and yields the thread back to the pool,
  so waits in flight are bounded by memory rather than by the thread pool.
- **HTTP/3** needs `libmsquic`, installed in the image.
