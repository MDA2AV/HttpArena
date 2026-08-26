---
title: Validation
seo_title: "API-16 Constrained Workload Benchmark: Validation Checks"
description: "The correctness checks validate.sh runs against the API-16 constrained workload before a framework's results are accepted."
---

The API-16 test uses a subset of endpoints. Subscribing to the `mini` test automatically triggers validation for all of them, even if the individual tests are not listed in `meta.json`:

- `/baseline11` - [Baseline validation](../../../isolated/baseline/validation) (GET, POST, chunked POST, anti-cheat)
- `/json` - [JSON Processing validation](../../../isolated/json-processing/validation) (structure, totals, Content-Type)
- `/async-db` - [Async Database validation](../../../isolated/async-database/validation) (structure, Content-Type, empty range)

