---
title: Validation
seo_title: "Rendezvous Benchmark: Validation Checks"
description: "Every check the validation script runs against the rendezvous endpoint, and the failure each one catches."
---

The load generator doesn't read response bodies, so these checks are the whole anti-cheat. They run from `scripts/validate-rendezvous.py`, with keys and values drawn fresh on every run.

| Check | What it does | What it catches |
|---|---|---|
| Each side gets the other's value | Two requests on one key with values of 1 and 32 characters. Each must be answered `200` with the other's value, verbatim | Echoing your own value, a fixed-size buffer, parsing `v` as a number |
| Content-Type | Both responses must be `text/plain` | The wrong response path |
| A lone request waits | One request, no partner: it must still be unanswered after 0.4s | Answering without waiting for the partner |
| The second request releases it | The partner arrives, and both must be answered | A waiter that never wakes |
| 256 pairs at once | 512 connections, one side of each pair first in random order, then the other sides. Every connection must get its own partner's value | Pairing by anything but the key, and a per-worker map, which loses any pair split across workers |
| Same key, 20 rounds | Two connections exchange 20 times on one key | A key that isn't freed, stale values, connections that don't stay usable |
| Still serving after a waiter disconnects | A client leaves while waiting, then a fresh pair must complete | A crash or a stuck worker when a parked response has nowhere to go |
