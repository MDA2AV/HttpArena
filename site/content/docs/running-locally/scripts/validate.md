---
title: validate.sh
seo_title: "validate.sh: Correctness Validation"
description: "Run the correctness suite against a framework: builds the image, starts the container and sidecars, and checks every subscribed endpoint."
weight: 1
---

Run the validation suite against a framework. Builds the Docker image, starts the container (and Postgres sidecar if needed), and runs correctness checks for every test profile listed in the framework's `meta.json`.

```bash
./scripts/validate.sh <framework>
```

## What it does

1. Reads the framework's `meta.json` to determine which tests are subscribed
2. Builds the Docker image
3. Mounts only the data volumes required by the subscribed tests
4. Starts a Postgres sidecar when `async-db`, `fortunes`, `gateway-64`, `gateway-h3` or `production-stack` is subscribed
5. Waits for the server to start (up to 30 seconds)
6. Runs all validation checks for the subscribed tests
7. Prints a pass/fail summary and exits with code 1 if any check failed

There is no option to validate a single profile: every profile in `meta.json` is checked on each run.

## Validation coverage

Each subscribed test triggers its corresponding validation checks. Profiles that reuse another profile's endpoint are covered by that profile's checks - the fixed-rate `latency-*` profiles, for example, run the full baseline suite.

An entry with `"tls_check": true` in `meta.json` also runs the opt-in [TLS hardening](/docs/test-profiles/h1/tls/validation/) section.

On failure, each check prints a link to the relevant validation documentation page for reference.

## Anti-cheat checks

Several validations use randomized inputs, drawn fresh on every run, to detect hardcoded responses:

- **Baseline**: random query parameters and POST bodies
- **JSON**: random counts and multipliers, with every item compared against `data/dataset.json`
- **Async**: random delays, and 32 overlapping requests that each carry a different delay
- **8Gbit**: random bodies that must be echoed back byte for byte
- **Async DB**: random price ranges and limits, plus an empty range that must return zero results
- **Static files**: a file replaced on disk must be served with its new bytes

## Example output

```
=== Validating: express ===
[info] Subscribed tests: baseline json-comp 8gbit
[build] Building Docker image...
[ready] Server is up
[test] baseline endpoints
  PASS [GET /baseline11?a=13&b=42]
  PASS [POST /baseline11?a=13&b=42 body=20]
  ...
[test] json endpoint
  PASS [GET /json/{count}?m=X] (4 counts × multipliers + full item schema verified)
  PASS [GET /json Content-Type] (Content-Type: application/json)
  ...

=== Results: 15 passed, 0 failed ===
```
