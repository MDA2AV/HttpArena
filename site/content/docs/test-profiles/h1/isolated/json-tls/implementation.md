---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard JSON serialization and a standard TLS stack (OpenSSL, BoringSSL, rustls, SChannel, JDK JSSE, etc.). No pre-serialized caches, no bypassing the framework response pipeline, no TLS session-ticket shortcuts that skip real handshakes." tuned="May use alternative JSON libraries, tuned TLS providers, and framework-specific optimizations. The JSON body must still be serialized per request from live data — pre-computed / pre-serialized response caches are not allowed on either type; they short-circuit the serialization workload the profile exists to measure." engine="No specific rules." >}}

The JSON over TLS profile is the [JSON Processing](../json-processing/implementation/) workload transported over HTTP/1.1 + TLS on a dedicated port. It measures how much of a framework's plaintext JSON throughput survives encryption.

## How it works

1. The framework loads `/data/dataset.json` at startup (same 50-item mixed-type dataset as the plain `json` profile)
2. The framework listens on **port 8081** with HTTPS, serving HTTP/1.1 only (ALPN advertises `http/1.1`)
3. On each `GET /json/{count}?m={multiplier}` request, the server returns the same response shape as the `json` profile: first `count` items with `total = price × quantity × m`, wrapped in `{items, count}`
4. Returns `Content-Type: application/json`
5. Client sends **no** `Accept-Encoding` header — compression is out of scope for this profile

The load generator is **wrk** with a Lua rotation script (`requests/json-tls-rotate.lua`). gcannon is not used for this test because it doesn't support TLS.

## What it measures

- Everything [JSON Processing](../json-processing/implementation/#what-it-measures) measures
- **TLS handshake cost amortized over keep-alive** — connections are long-lived at 4096 concurrent
- **Record framing overhead** — every HTTP request gets wrapped in one or more TLS records
- **Symmetric cipher throughput** — AES-GCM / ChaCha20-Poly1305 on the hot path
- **Certificate private-key operations** — RSA/ECDSA cost per new connection, mostly negligible with keep-alive but visible during ramp

## Port, ALPN, and certificates

- **Port**: 8081 (distinct from 8080 plaintext and 8443 which is dedicated to HTTP/2 / HTTP/3 profiles)
- **ALPN**: advertise `http/1.1` only. HTTP/1.1-only clients (wrk) negotiate correctly and never upgrade to h2.
- **Certificates**: the same PEM files used by `baseline-h2` / `static-h2`, mounted at `/certs/server.crt` and `/certs/server.key`. Frameworks typically read them via environment variables (`TLS_CERT`, `TLS_KEY`) or a hardcoded path, same pattern as the other TLS tests.

## Expected response

For `GET /json/5?m=3` over HTTPS on port 8081:

```
HTTP/1.1 200 OK
Content-Type: application/json
```

Body (same as the plain `json` profile):

```json
{
  "items": [
    {
      "id": 1,
      "name": "Alpha Widget",
      "category": "electronics",
      "price": 328,
      "quantity": 15,
      "active": true,
      "tags": ["fast", "new"],
      "rating": { "score": 48, "count": 127 },
      "total": 14760
    }
  ],
  "count": 5
}
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `GET /json/{count}?m={multiplier}` |
| Transport | HTTP/1.1 over TLS |
| Port | 8081 |
| ALPN | `http/1.1` |
| Count × multiplier pairs | `(1,3)`, `(5,7)`, `(10,2)`, `(15,5)`, `(25,4)`, `(40,8)`, `(50,6)` (round-robin) |
| Connections | 4,096 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Load generator | wrk + `requests/json-tls-rotate.lua` |
| Certificates | mounted at `/certs/server.crt` + `/certs/server.key` |
| Dataset | 50 items, mounted at `/data/dataset.json` |
