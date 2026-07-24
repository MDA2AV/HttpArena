---
title: Validation
---

The HTTP/3 static files profile does not have dedicated validation checks in `validate.sh`. HTTP/3 (QUIC) validation relies on:

- The [HTTP/2 Static Files validation](../../h2/static-h2/validation) checks, which verify Content-Type headers, response sizes, and 404 handling over HTTPS on port 8443
- The benchmark runner itself, which confirms the framework responds to HTTP/3 requests via `oha`

The static file endpoints are shared between HTTP/2 and HTTP/3 profiles - both serve on port 8443 with TLS.
