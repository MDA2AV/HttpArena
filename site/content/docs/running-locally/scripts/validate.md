---
title: validate.sh
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
4. Starts a Postgres sidecar when `async-db`, `api-4`, or `api-16` tests are enabled
5. Waits for the server to start (up to 30 seconds)
6. Runs all validation checks for the subscribed tests
7. Prints a pass/fail summary and exits with code 1 if any check failed

## Validation coverage

Each subscribed test triggers its corresponding validation checks. Workload profiles (`api-4`, `api-16`) automatically trigger validation for all endpoints they use, even if those individual tests are not in `meta.json`.

On failure, each check prints a link to the relevant validation documentation page for reference.

## Anti-cheat checks

Several validations use randomized inputs to detect hardcoded responses:

- **Baseline**: random query parameters and POST bodies
- **Upload**: random binary payload with byte count verification
- **Database / Async DB**: empty price range that must return zero results

## Example output

```
=== Validating: express ===
[info] Subscribed tests: baseline json upload
[build] Building Docker image...
[ready] Server is up
[test] baseline endpoints
  PASS [GET /baseline11?a=13&b=42]
  PASS [POST /baseline11?a=13&b=42 body=20]
  ...
[test] json endpoint
  PASS [GET /json] (50 items, totals computed correctly)
  PASS [GET /json Content-Type] (Content-Type: application/json)
  ...

=== Results: 15 passed, 0 failed ===
```
