---
title: Validation
seo_title: "Compliance: /spec Validation Checks"
description: "How the spec list in meta.json is checked, and what validate.sh checks on the /spec route for the h1 and h2 suites."
---

The compliance suites an entry subscribes to are listed in the `spec` field of `meta.json`, the way profiles are listed in `tests`. It is a field of its own because nothing in it is measured:

```json
"tests": ["baseline", "baseline-h2", "baseline-h2c", "baseline-h3"],
"spec": ["h1", "h2", "h3"]
```

Two checks run before anything is built, like the one on `tests`:

- **Unknown names fail.** The suites are `h1`, `h2`, `h3` and `ws`. A typo would otherwise drop a column without a word.
- **A suite needs a profile to run against.** `h1` needs an HTTP/1.1 profile on 8080; `h2` one of `baseline-h2`, `static-h2`, `baseline-h2c` or `json-h2c`; `h3` one of `baseline-h3` or `static-h3`; `ws` one of the echo-ws profiles.

Then `/spec` is checked for `h1` and `h2`, on every listener that suite uses: serving it on 8080 and forgetting it on 8443 fails rather than quietly losing the H/2 column. `h3` and `ws` need no route, so there is nothing more to check for them here. A suite the entry does not list is not checked, and shows as not measured in its column.

Bodies are random bytes, so a canned response cannot pass, and every echo is compared byte for byte.

## `h1`: HTTP/1.1 on 8080

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

## `h2`: HTTP/2 on 8443 and 8082

What h2spec needs, on each HTTP/2 listener the entry runs:

| Check | What it establishes |
|---|---|
| `GET /spec` over HTTP/2 | `200`, HTTP/2 on the wire, a body of at least 5 bytes |
| `POST /spec` over HTTP/2, random 1 KB body | echoed byte for byte |
