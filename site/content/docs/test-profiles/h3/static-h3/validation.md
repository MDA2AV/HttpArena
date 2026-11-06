---
title: Validation
seo_title: "Static File Serving Benchmark (HTTP/3): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP/3 static file benchmark before a framework's results are accepted."
---

`validate.sh` requests `/static/reset.css` four times over QUIC and requires all four to come back `2xx`:

```
PASS [static-h3 over QUIC] (4/4 2xx, ALPN h3)
```

It then does the same for the percent-encoded file, `/static/%7E%40file%20name.txt`, which is one of the 21 URIs the profile rotates over. An HTTP/3 stack can take a path apart differently from the h1/h2 listener of the same entry, so the benchmark's own spelling has to resolve over QUIC too:

```
PASS [static-h3 percent-decoded path over QUIC] (4/4 2xx for /static/%7E%40file%20name.txt)
```

The full set of spellings, and the check that the path is decoded only once, run over HTTP/2 in [HTTP/2 Static Files validation](/docs/test-profiles/h2/static-h2/validation/#percent-encoded-path).

There is no HTTP/3 client in the validator's base image and OpenSSL cannot speak QUIC, so the check runs the same ngtcp2-built `h2load` the benchmark uses, with `--alpn-list=h3`. If that image has not been built the check reports `SKIP` and is counted as skipped. It never passes silently.

This profile previously had no checks of its own and leaned on the HTTP/2 static validation, which only covers an entry that also subscribes to an h2 profile. An entry subscribing to H3 alone ran no assertions at all and still exited 0. Content-Type, response sizes and 404 handling are still asserted over h2 by [HTTP/2 Static Files validation](../../h2/static-h2/validation) for entries that serve both on port 8443.
