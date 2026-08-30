---
title: Validation
seo_title: "HTTP Pipelining Benchmark (16x): Validation Checks"
description: "The correctness checks validate.sh runs against the HTTP pipelining benchmark before a framework's results are accepted."
---

The following checks are executed by `validate.sh` for every framework subscribed to the `pipelined` test.

## GET /pipeline response

Sends `GET /pipeline` and verifies the response body is exactly `ok`.
