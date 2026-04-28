---
title: Validation
---

The validation script (`scripts/validate.sh`) runs these checks for the `json-comp` test profile. All must pass for a framework to be considered valid for this benchmark.

## Checks

### Content-Encoding is set when Accept-Encoding is sent

```
GET /json/50?m=1
Accept-Encoding: gzip, br
```

The response must include `Content-Encoding: gzip` or `Content-Encoding: br`. Any other value (including absent) is a failure.

### Response body is correct for multiple (count, m) pairs

Three requests are sent with different counts and multipliers:

| Count | Multiplier |
|-------|-----------|
| 25 | 3 |
| 40 | 7 |
| 50 | 2 |

For each response, after decompressing, the validator checks:

1. `count` field equals the route count
2. Every item in `items` has a `total` field
3. `total == price * quantity * m` for every item (integer, exact)

Any missing field or incorrect arithmetic is a failure. This confirms the server honors the `m` parameter and applies it per item.

### No Content-Encoding when Accept-Encoding is absent

```
GET /json/50?m=1
```

Without `Accept-Encoding`, the response **must not** include a `Content-Encoding` header. Compression is driven per request by the client — servers that unconditionally compress fail this check.

## Running locally

```bash
./scripts/validate.sh <framework>
```

Filter to this profile only:

```bash
./scripts/validate.sh <framework> json-comp
```
