---
title: Validation
seo_title: "HTTP/3 Baseline Benchmark (QUIC): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/3 baseline benchmark before a framework's results are accepted."
---

`validate.sh` sends four requests to `/baseline2?a=13&b=42` over QUIC and requires all four to come back `2xx`:

```
PASS [baseline-h3 over QUIC] (4/4 2xx, ALPN h3)
```

There is no HTTP/3 client in the validator's base image and OpenSSL cannot speak QUIC, so the check runs the same ngtcp2-built `h2load` the benchmark uses, with `--alpn-list=h3`. If that image has not been built the check reports `SKIP` and is counted as skipped. It never passes silently.

This profile previously had no checks of its own and leaned on the HTTP/2 baseline validation, which only covers an entry that also subscribes to an h2 profile. An entry subscribing to H3 alone ran no assertions at all and still exited 0. Entries that serve `/baseline2` over both h2 and h3 on port 8443 are still covered by [HTTP/2 Baseline validation](../../h2/baseline-h2/validation) as well.
