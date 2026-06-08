---
title: Implementation Guidelines
---
{{< type-rules production="Must render the response with a real template engine - one with a documented templating syntax, variable interpolation, control flow (loop/if), and HTML auto-escaping by default. Examples: Razor / Razor Pages / Razor Components, Jinja2, ERB, Twig, Blade, html/template, Thymeleaf, Freemarker, Handlebars, Pug, Liquid, Tera, Askama, Maud, templ. The template must be a separate artifact (file, embedded resource, or compile-time component) - not inline string concatenation in the handler. No pre-rendered or cached response bodies; the template must execute per request." tuned="May use any rendering strategy, including hand-rolled string concatenation, custom HTML emitters, StringBuilder / Buffer-based builders, byte-slice writers, or compile-time templating with framework-specific source generators. The handler must still query the database, append the runtime-injected row in memory, sort, and HTML-escape user content per request - pre-rendered response bodies and bypass-the-engine response caches are not allowed on either type. The runtime row's text is fixed, but the page still must be rendered per request because validation reads the body byte-for-byte." engine="No specific rules. Engines without an HTTP application layer typically don't subscribe to this profile." >}}

The Fortunes profile measures template-engine throughput on a realistic page-rendering pipeline: query 200 rows from Postgres, append a runtime row in memory, sort, and render an HTML page via the framework's chosen template engine.

**Diverges from TechEmpower Fortunes (12-row spec) by design.** With only 12 rows the per-request render time is dwarfed by the PG round-trip, so the profile ends up measuring the database driver more than the template engine. Bumping the seed to 200 rows scales render cost linearly while leaving query cost effectively constant (still one round-trip, still single-page table read), shifting the bottleneck from PG-throughput to framework-CPU - which is what the profile name actually claims to measure.

**This test is reference-only - it does not contribute to the composite score.** It exists for engine-to-engine comparison (Razor vs Jinja2 vs ERB vs Askama, etc.), not framework ranking. Frameworks without a template engine should leave it out of `meta.json.tests`.

**Connections:** 1,024

## How it works

1. A Postgres container runs alongside the framework container on the same host, listening on `localhost:5432`. The same connection pool used by `async-db` / `crud` is shared.
2. On each `GET /fortunes` request the framework:
   - Reads all 200 rows from the `fortune` table (`id`, `message`).
   - Appends a runtime row in memory: `{ id: 0, message: "Additional fortune added at request time." }` - total 201 rows.
   - Sorts the combined list by `message` using ASCII / ordinal byte order (not locale-aware).
   - Renders an HTML page containing a `<table>` with one `<tr>` per fortune.
3. Returns `Content-Type: text/html` (with optional `; charset=utf-8`).

The runtime-injected row is the load-bearing design decision - it forces the rendered HTML to differ structurally from the raw DB result, which makes "cache the whole page once and serve bytes" optimizations invalid.

## What it measures

- **Template engine throughput** - interpolation, loop expansion, layout/partial composition.
- **HTML escape correctness** - row 11 contains a raw `<script>` tag in the database; the engine must emit it as `&lt;script&gt;` in the rendered output. Auto-escape is the safe default in every modern engine; this profile pins that down as a contractual requirement.
- **End-to-end pipeline cost** - Postgres read + sort + render + response write, all on one event-loop tick.

## Database schema

The `fortune` table in Postgres (200 rows seeded; same Postgres instance as `async-db` / `crud`):

```sql
CREATE TABLE fortune (
    id      INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

Rows 1–12 match the TechEmpower Fortunes seed (including the `<script>` row at id 11, which is the load-bearing escape check). Rows 13–200 are synthetic adages generated to give the renderer per-row work - each contains `&`, `'`, `"`, and an em-dash so the engine's escape codepath runs on every cell, not just on row 11. See `data/pgdb-seed.sql` for the exact rows.

## SQL query

```sql
SELECT id, message FROM fortune
```

No `ORDER BY` - the framework sorts in-memory after appending the runtime row.

## Runtime row injection

After the DB query and before sorting, append:

```
{ id: 0, message: "Additional fortune added at request time." }
```

The id `0` and the literal text are fixed across all frameworks for validation parity.

## Sort

Sort the combined 201-row list by `message` using ordinal / byte / ASCII comparison. With the seed data this puts the `<script>...` row first (`<` is 0x3C, lower than any letter) and the multi-byte UTF-8 rows last.

Locale-aware comparison is **not** allowed because it produces different orderings on different runtimes - use the ordinal/byte equivalent of your language's `String.CompareOrdinal` / `bytes.Compare` / `strcmp`.

## Expected response

```
GET /fortunes HTTP/1.1
```

A complete HTML document with:
- `Content-Type: text/html` (charset optional but recommended)
- `<!DOCTYPE html>` declaration
- A `<table>` with one header row (`<tr><th>id</th><th>message</th></tr>`) and 201 data rows.
- All `message` values HTML-escaped - row 11 must render as `&lt;script&gt;...&lt;/script&gt;`, never as a raw `<script>` tag.

Total body size lands between roughly 18–40 KB depending on engine formatting.

Validation does not enforce byte-for-byte equality - it checks features (Content-Type, DOCTYPE, row count, runtime-row text, escape correctness, body size band). See [Validation](validation/) for exact checks.

## Production vs Tuned

**Production** entries should look like idiomatic templated HTML in the framework - a `.cshtml` Razor page, a Jinja2 template loaded via `flask.render_template`, an ERB view in Sinatra, a `templ` component in Go, etc. The template lives in its own file and is composed (or compiled) by the engine. Auto-escaping is on; user content goes through `@variable` / `{{ variable }}` syntax that escapes by default.

**Tuned** entries are free to skip the engine entirely - emit HTML via `StringBuilder.Append`, `bytes.Buffer.WriteString`, manual `<<` concatenation, custom byte-slice writers. This mirrors what many TechEmpower Fortunes entries do to chase peak throughput. The handler must still:
- Query the DB per request (no pre-rendered response cache).
- Append the runtime row (the page must vary per request relative to a hypothetical cache that snapshots only the DB rows).
- HTML-escape user content correctly. A custom emitter must implement escaping for `<`, `>`, `&`, `"`, `'` at minimum.

The Standard/Tuned distinction is recorded in `meta.json.mode` and shown on the leaderboard so users can compare "what the framework's template engine does" against "what the framework's hand-tuned hot path does."

## Why this profile is unscored

Template engine choice dominates the result far more than HTTP-stack quality. A framework using a compile-time engine like Razor source-gen, Askama, Maud, or `templ` will look 5–10× faster than the same framework using a runtime-parsed engine like Jinja2 or ERB. That gap is real and worth showing - but rolling it into the composite would let template-engine choice swamp legitimate framework comparisons on baseline / JSON / async-db. So Fortunes is published, comparable, and visible on the leaderboard, but does not contribute to the composite score.

## Why 200 rows instead of TE's 12

TechEmpower Fortunes uses 12 rows - at that size, the per-request render takes microseconds and the dominant cost is the PG round-trip + network protocol, not the template engine. Frameworks with the same template engine but different DB drivers end up ranked by DB driver, defeating the profile's purpose.

Bumping to 200 rows scales render cost linearly (more interpolation, more escape work, more bytes to write) while leaving query cost effectively flat (the table still lives in a single 8 KB shared-buffer page; one round-trip serializes 200 rows nearly as fast as 12). At 1024 connections the bottleneck shifts from PG-throughput to framework-CPU - i.e. the actual template engine. That's the trade: lose direct TE leaderboard comparability, gain a column that means what its name says.
