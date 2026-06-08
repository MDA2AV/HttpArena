---
title: Validation
---

The short-lived connection profile uses the same `/baseline11` endpoint as the baseline test. Its validation is covered by the [Baseline validation](../../baseline/validation) checks, which run for every framework subscribed to either `baseline` or `limited-conn`.

No additional validation checks are specific to this profile - the difference is in benchmark behavior (connections close after 10 requests), not in endpoint correctness.
