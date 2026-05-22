---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `fortunes` test. A Postgres sidecar container is started automatically before these checks run.

Validation is **feature-based, not byte-exact**. Engines disagree on whitespace, attribute order, quote style, and self-closing tags — enforcing byte equality would turn the contest into "who can torture their template into emitting the canonical form" rather than "whose engine renders fast." The checks below pin down the work envelope (loop iterated, runtime row appended, escape applied, layout rendered, body has a real size) without dictating output format.

## Content-Type header

Sends `GET /fortunes` and verifies the `Content-Type` response header contains `text/html` (a `; charset=utf-8` suffix is allowed and recommended).

## DOCTYPE present

Verifies the response body contains `<!DOCTYPE html>` (case-insensitive). This proves a layout / partial / outer template fired — a handler that only emits a fragment will fail this check.

## Row count

Counts `<tr` occurrences in the response body. The expected band is **201–210**:

- 201 data rows (200 seeded + 1 runtime-injected) are required.
- A `<tr>` header row (`<tr><th>id</th><th>message</th></tr>`) is allowed but not required.
- The upper bound absorbs implementation-specific extras (a footer summary row, etc.) without forcing a specific shape.

A count below 201 means the loop didn't iterate every row. Above 210 means the engine emitted unexpected scaffolding.

## Runtime-injected row present

Verifies the body contains the literal string `Additional fortune added at request time.`. This proves the handler appended the in-memory row instead of rendering only the DB rows. Without this check, "cache the rendered HTML once and serve bytes" passes everything else.

## XSS escape (load-bearing)

The DB seed contains `<script>alert("This should not be displayed in a browser alert box.");</script>` as the message of row 11. The validator asserts:

- Body contains `&lt;script&gt;` (the escape happened), AND
- Body does NOT contain the raw `<script>alert` substring anywhere.

This is the most important check in the profile. Without it, a "template engine" that skips escaping wins the bench — which is both a security regression and the obvious gaming vector. Frameworks failing this check are not running a real template engine, full stop.

## Body size band

Verifies the response body length is between **18 KB and 64 KB**. A 201-row HTML table with a layout typically lands around 22–30 KB; the band catches:

- Stripped pages (handler returned only fragments to win throughput).
- Empty bodies (template failed silently and the engine emitted nothing).
- Pathologically large output (an unintended layout loop or duplicated content).

The upper bound is generous — engines that emit more whitespace, longer DOCTYPEs, or a bigger header / footer will still pass.

## What is NOT validated

- **Sort order.** The implementation guidelines specify ordinal-byte sort, but the validator does not parse the rendered HTML and verify row positions. Frameworks shipping a different sort still pass — the production rules govern correctness here, not the validator.
- **Exact byte output.** Two correct implementations can produce different HTML and both pass.
- **Header row presence.** A `<tr><th>...</th></tr>` header row is recommended for parity with the reference rendering but not enforced.
- **Performance under load.** Validation is correctness-only; the benchmark driver measures throughput separately.
