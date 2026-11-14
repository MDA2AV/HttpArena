---
title: Validation
seo_title: "Compliance: /spec Validation Checks"
description: "What validate.sh checks on the /spec route, on each listener the entry runs, once the entry opts in with \"spec\": true."
---

Opt in with the `spec` field in `meta.json`. Like `tls_check`, it is a capability the entry declares rather than a profile it is measured on, so it has its own field instead of an entry in `tests`:

```json
"enabled": true,
"spec": true
```

Once it is set, the whole contract is checked on every listener the entry runs. Serving `/spec` on 8080 and forgetting it on 8443 fails validation rather than quietly losing the H/2 column. An entry without the field is not checked here, and its H/1.1 and H/2 compliance cells show as not measured.

Bodies are random bytes, so a canned response cannot pass, and every echo is compared byte for byte.

## HTTP/1.1 on 8080

| Check | What it establishes |
|---|---|
| `GET /spec` | `200` and a body of at least 5 bytes |
| `HEAD /spec` | `200` and nothing after the headers - read over a raw socket, not inferred by curl |
| `OPTIONS /spec` | `200` and an `Allow` header naming `GET`, `HEAD`, `POST` and `OPTIONS` |
| `POST /spec`, random 1 B, 1 KB and 64 KB bodies, no `Content-Type` | echoed byte for byte |
| `POST /spec`, chunked, 1 KB and 64 KB | decoded and echoed byte for byte |
| `POST /spec`, empty body | `200` with an empty body |
| `GET /spec/headers` with a random `X-Spec-Probe` value | `200` and a line `X-Spec-Probe: <value>`, name in any case |
| `POST /spec/headers` with a body | the same line, with the body read and discarded |

## HTTP/2 on 8443 and 8082

What h2spec needs, on each HTTP/2 listener the entry runs:

| Check | What it establishes |
|---|---|
| `GET /spec` over HTTP/2 | `200`, HTTP/2 on the wire, a body of at least 5 bytes |
| `POST /spec` over HTTP/2, random 1 KB body | echoed byte for byte |
