---
weight: 6
title: Database
seo_title: "Database Test Profiles"
description: "Postgres-backed HTTP/1.1 benchmarks that rank the whole path from request to query and back, with the server, load generator and database each on CPUs of their own."
---

Database profiles measure the whole path from request to query and back: the framework, its Postgres driver and any data-access layer on top. They run over HTTP/1.1 with the same load generator as the H/1.1 profiles, but rank on their own board, because the database and its driver dominate these numbers far more than the framework does.

## CPU layout

Postgres does real work here, so the box is split three ways instead of two. Every core is paired with its SMT sibling.

| Role | Logical CPUs | Cpuset |
|---|---:|---|
| Server | 32 | `0-15,64-79` |
| Load generator (32 threads) | 32 | `16-31,80-95` |
| Postgres | 64 | `32-63,96-127` |

{{< cards >}}
  {{< card link="async-database" title="Async Database (Postgres)" subtitle="Async Postgres range query over 100K rows, connection pooling, and JSON serialization." icon="database" >}}
  {{< card link="fortunes" title="Fortunes (Templates)" subtitle="DB query + HTML template rendering with auto-escape." icon="document-text" >}}
{{< /cards >}}
