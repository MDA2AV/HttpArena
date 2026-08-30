---
title: Validation
seo_title: "TLS Hardening: Validation Checks"
description: "The opt-in TLS section: certificate rotation, SNI, resumption, close_notify and the vulnerability suite, on the HTTP/1.1 TLS listener."
---

An **opt-in** section. Nothing here is measured and nothing here affects a score. It is a hardening bar an entry chooses to be held to, and passing it earns the TLS badge on the HTTP/1.1 composite.

Subscribe with the `tls_check` field in `meta.json`. It is a capability the entry opts into rather than a profile it is measured on, which is why it has its own field instead of an entry in `tests`:

```json
"enabled": true,
"tls_check": true
```

## A listener of its own, on :9000

The section needs **a second TLS listener on port 9000**, reading its certificate and key from **`/certs-tls`**. That directory is mounted for this entry alone and seeded from the usual pair.

This is not incidental. The section replaces certificates underneath a running server, and doing that to the shared `/certs` would move the ground under `json-tls`, `static-tls` and every h2 profile in the same validation run. A dedicated port and a private directory keep it from touching anything else, and `/certs` is never written to.

The listener is HTTP/1.1 over TLS. The h2 and h3 listeners are separate and not covered here, which is why the badge only appears on the H1 composite.

An entry that opts in without opening :9000 fails the section with a clear message rather than being skipped.

## Why it is opt-in

Most of these need the entry to have done something deliberate. Binding a certificate once at startup, which is what almost every entry does, fails the first check on this page. Opting in is a statement that the entry has gone further.

## Checks

### Certificate rotation

The certificate and key at `/certs-tls` are replaced with a freshly generated RSA-2048 pair while the server is running. The server must serve the new certificate **without a restart**, within 30 seconds, and must still answer requests on it.

A certificate is renewed roughly every 60 days in production. A server that needs a restart to pick one up is a weaker server, and nothing else in the suite notices the difference.

The usual way to pass is a per-handshake certificate callback rather than a value bound at startup: `ServerCertificateSelector` in Kestrel, `tls.Config.GetCertificate` in Go, a `ResolvesServerCert` in Rust with rustls.

### Rotation keeps serving

Thirty requests are issued across the swap. All of them must succeed. Rotating by dropping traffic is not rotating.

### SNI

The server must complete a handshake both **with** a server name and **without** one. A client that omits SNI has to get a usable answer rather than a dropped connection.

### Session resumption

Reported, not required. If the server issues a session ticket, a second connection presenting it should resume. An entry that issues no ticket makes every connection pay a full handshake, which is worth knowing but is not a failure.

### close_notify

The server must close at the TLS layer rather than dropping the socket. Without the alert, a truncated response is indistinguishable from a complete one.

### Vulnerability suite

[testssl.sh](https://github.com/testssl/testssl.sh) `-U`, which covers Heartbleed, CCS, Ticketbleed, ROBOT, secure renegotiation, CRIME, BREACH, POODLE, `TLS_FALLBACK_SCSV`, SWEET32, FREAK, DROWN, LOGJAM, BEAST, LUCKY13, Winshock and RC4. It takes about 30 seconds. Any **HIGH** or **CRITICAL** finding fails the section.

Set `HTTPARENA_SKIP_TLS_SCAN=1` to skip it; it also skips itself rather than failing an entry when the scanner image is unavailable.

### The shared TLS checks

The section also runs everything the TLS-carrying profiles already run. The certificate must be the one the harness mounted, the connection must negotiate TLS 1.3 with an AEAD cipher, ALPN must not name a protocol the client did not offer, and no obsolete protocol or weak cipher may be accepted. See [json-tls validation](../json-tls/validation/#tls-checks).

## The badge

Two badges, and they mean different things:

| badge | meaning |
|---|---|
| green shield | the TLS basics, checked on any entry with a TLS profile |
| **gold shield** | opted into this section **and passed it** |

Both are earned by the probes, never declared in `meta.json`. No badge means *not verified*, since most entries have no TLS profile at all. It never means *failed*.

## Running locally

```bash
./scripts/validate.sh <framework>
```

The rotation checks replace files in the private `/certs-tls` directory and put them back afterwards, including when a check fails midway. The shared `certs/` directory is never written to.
