---
title: Validation
seo_title: "Static File Serving Benchmark (HTTP/3): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/3 static file benchmark before a framework's results are accepted."
---

`validate.sh` requests `/static/reset.css` four times over QUIC and requires all four to come back `2xx`:

```
PASS [static-h3 over QUIC] (4/4 2xx, ALPN h3)
```

There is no HTTP/3 client in the validator's base image and OpenSSL cannot speak QUIC, so the check runs the same ngtcp2-built `h2load` the benchmark uses, with `--alpn-list=h3`. If that image has not been built the check reports `SKIP` and is counted as skipped. It never passes silently.

This profile previously had no checks of its own and leaned on the HTTP/2 static validation, which only covers an entry that also subscribes to an h2 profile. An entry subscribing to H3 alone ran no assertions at all and still exited 0. Content-Type, response sizes and 404 handling are still asserted over h2 by [HTTP/2 Static Files validation](../../h2/static-h2/validation) for entries that serve both on port 8443.
