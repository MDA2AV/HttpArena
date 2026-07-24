---
title: Validation
---

The HTTP/3 baseline profile does not have dedicated validation checks in `validate.sh`. HTTP/3 (QUIC) validation relies on:

- The [HTTP/2 Baseline validation](../../h2/baseline-h2/validation) checks, which verify the `/baseline2` endpoint works correctly over HTTPS on port 8443
- The benchmark runner itself, which confirms the framework responds to HTTP/3 requests via `oha`

The `/baseline2` endpoint is shared between HTTP/2 and HTTP/3 profiles - both serve on port 8443 with TLS.
