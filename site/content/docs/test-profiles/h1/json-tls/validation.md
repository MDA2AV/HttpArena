---
title: Validation
seo_title: "JSON over TLS Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the JSON over TLS benchmark before a framework's results are accepted."
---

The validation script (`scripts/validate.sh`) runs these checks for the `json-tls` test profile. All must pass for a framework to be considered valid for this benchmark.

## Checks

### ALPN negotiates HTTP/1.1

```
curl -sk --http1.1 https://localhost:8081/json/1?m=1
```

The response must report `http_version = 1.1`. A framework that advertises only `h2` on port 8081, or that refuses HTTP/1.1 clients, fails this check.

### Response body is correct for multiple (count, m) pairs

Three requests are sent over HTTPS on port 8081 with different counts and multipliers:

| Count | Multiplier |
|-------|-----------|
| 7 | 2 |
| 23 | 11 |
| 50 | 1 |

For each response the validator checks:

1. `count` field equals the route count
2. Every item in `items` contains the full schema - `id`, `name`, `category`, `price`, `quantity`, `active`, `tags` (array), `rating` (object with `score` and `count`), and `total`
3. `total == price * quantity * m` for every item (integer, exact)

These `(count, m)` pairs are deliberately **different** from the `json-comp` validation pairs so a framework that tries to cache validation results across profiles can't pass both.

### Content-Type is application/json

```
curl -sk -D- -o /dev/null https://localhost:8081/json/1?m=1
```

The response must include a `Content-Type` header containing `application/json`.

## TLS checks

These run on every profile that uses TLS: `json-tls` and `static-tls` on port 8081, `baseline-h2` and `static-h2` on 8443. They ask two separate questions: what this connection negotiated, and what the server is willing to negotiate at all.

### Serves the certificate the harness mounted

```
openssl s_client -connect localhost:8081 -servername localhost
```

The leaf certificate must match `certs/server.crt` by SHA-256 fingerprint. An entry that ignores `/certs` and generates its own pair fails.

This is not a formality. Every TLS handshake costs the server **one signature** with that key, and the mounted pair is RSA-2048. On the benchmark host:

| key | signatures/sec |
|-----|---------------|
| RSA-2048 | 3,052 |
| ECDSA P-256 | 77,124 |

An entry that quietly swaps in an EC certificate gets handshakes **25× cheaper** on the signing step than every entry that uses the mounted one. Nothing else in the suite would notice.

### Negotiates TLS 1.3

The client offers TLS 1.3. A server that settles on 1.2 fails: the 1.2 handshake costs an extra round trip, so its connection-setup numbers are not comparable with the rest of the field.

### Uses a TLS 1.3 AEAD cipher

The negotiated suite must be one of `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384` or `TLS_CHACHA20_POLY1305_SHA256`. This rules out a NULL, anonymous, export or RC4 suite making "TLS" effectively free.

**Which of the three is chosen is reported, not required.** In TLS 1.3 the server picks, and the field is split. Some entries choose AES-128-GCM and some AES-256-GCM, which measure roughly **17% apart** on bulk encryption at static-file block sizes. Not every framework exposes cipher preference, so the choice is recorded in the validation output rather than failed.

### ALPN never names a protocol the client did not offer

Selecting **nothing** is fine: a server without ALPN omits the extension and the client falls back, which is correct on the HTTP/1.1 ports. What fails is answering with a protocol that was not offered, which would silently measure something other than the profile names.

### Accepts no obsolete protocol or weak cipher

A server can hand a modern client TLS 1.3 and still accept TLS 1.0, RC4 or a NULL cipher from anything else that asks. The validator offers each of these directly and **fails** when a handshake actually completes. An alert, a reset or a timeout counts as a refusal:

- `SSLv2`, `SSLv3`, `TLS 1.0`, `TLS 1.1`
- NULL ciphers (no encryption)
- anonymous ciphers (no authentication)
- export-grade ciphers
- 64-bit, DES, RC2, RC4 or MD5 ciphers
- 3DES / IDEA

OpenSSL will not offer an SSLv3 or TLS 1.0 handshake, nor a NULL/EXPORT/RC4 one, at its default security level, so the probes use `@SECLEVEL=0` to make the question askable at all. A protocol the local OpenSSL cannot offer is reported as unprobed rather than counted as refused. The whole set costs about 70ms per port.

> [testssl.sh](https://github.com/testssl/testssl.sh) is the reference tool for this question and agrees with these checks. It is what surfaced the first real failure here. It is the better choice for an audit, where its much wider suite coverage and its SSL Labs style grade are worth the time: a full run costs ~48s per port and caps every entry at **B** on *chain incomplete*, which is an artifact of the self-signed certificate the harness mounts rather than anything about the entry.

## Running locally

```bash
./scripts/validate.sh <framework>
```

Filter to this profile only:

```bash
./scripts/validate.sh <framework> json-tls
```
