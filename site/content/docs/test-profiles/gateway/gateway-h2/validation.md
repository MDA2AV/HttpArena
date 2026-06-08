---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `gateway-64` test. The validation script builds and starts the full compose stack from `compose.gateway.yml` before running checks.

All requests are sent over HTTPS with HTTP/2 to port **8443** - the same port the load generator uses during benchmarking. This validates the full end-to-end path through the proxy (or directly to the server if no proxy is used), not just the server in isolation.

## Stack startup

1. The Postgres sidecar is started (needed for `/async-db` endpoint)
2. The compose stack is built and started via `docker compose -f compose.gateway.yml up --build -d`
3. Validation waits up to 30 seconds for HTTPS on port 8443 to respond
4. All checks run against `https://localhost:8443`
5. The compose stack is torn down after validation completes

## HTTP/2 protocol negotiation

Sends a request to `https://localhost:8443/static/reset.css` and verifies the response uses **HTTP/2** (via ALPN). This confirms TLS and h2 are correctly configured at the entry point (proxy or server).

## Static file checks

### Content-Type headers

Verifies correct `Content-Type` headers for representative file types over HTTPS with HTTP/2:

- `GET /static/reset.css` - expects `Content-Type: text/css`
- `GET /static/app.js` - expects `Content-Type: application/javascript`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

### Response size

Requests `GET /static/app.js` over HTTP/2 and verifies the response size is greater than 0 bytes. This confirms the proxy is correctly forwarding to the server and the server is returning file content.

### 404 for nonexistent file

Sends `GET /static/nonexistent.txt` over HTTP/2 and verifies the response is **HTTP 404**. The 404 must propagate correctly through the proxy.

## JSON endpoint checks

### Response structure

Sends `GET /json` over HTTP/2 and validates:

- Response contains exactly **50 items**
- Every item carries the full schema - `id`, `name`, `category`, `price`, `quantity`, `active`, `tags` (array), `rating` (object with `score` and `count`), and `total`
- Each `total` is correctly computed as `price * quantity` (rounded to 2 decimal places)

This is the same validation as the [JSON Processing test](../../h1/isolated/json-processing/validation), but routed through the proxy.

### Content-Type header

Verifies the response has `Content-Type: application/json`.

## Async database checks

### Response structure

Sends `GET /async-db?min=10&max=50` over HTTP/2 and validates:

- Response count is between 1 and 50
- Every item has a nested `rating` object with a `score` field
- Every item has a `tags` array
- Every item's `active` field is a boolean (not a string or integer)

This is the same validation as the [Async Database test](../../h1/isolated/async-database/validation), but routed through the proxy.

### Content-Type header

Verifies the response has `Content-Type: application/json`.

### Anti-cheat: empty range

Sends `GET /async-db?min=9999&max=9999` and verifies the response returns `count: 0`. This detects hardcoded or cached responses that don't actually query the database.

## Baseline endpoint checks

### Fixed input

Sends `GET /baseline2?a=13&b=42` over HTTP/2 and verifies the response body is `55` (the sum of the two query parameters). This confirms the proxy correctly forwards query parameters to the application server.

### Anti-cheat: randomized input

Sends `GET /baseline2?a=<random>&b=<random>` with random values and verifies the response matches the expected sum. This detects hardcoded responses.

## Prerequisite checks

The gateway-64 test relies on endpoint implementations that are validated individually in other test profiles:

- `/json` - [JSON Processing validation](/docs/test-profiles/h1/isolated/json-processing/validation)
- `/static/*` - [Static Files validation](/docs/test-profiles/h1/isolated/static/validation)
- `/async-db` - [Async Database validation](/docs/test-profiles/h1/isolated/async-database/validation)
- `/baseline2` - [Baseline H2 validation](/docs/test-profiles/h2/baseline-h2/validation)

Frameworks subscribing to `gateway-64` should also subscribe to these individual tests to ensure each endpoint passes validation independently before testing through the proxy.
