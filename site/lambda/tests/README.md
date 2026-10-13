# Tests

## What has to keep working

- The site: `/` is the board, a folder answers with its `index.html` (`docs/scoring/`), and a
  path that is nothing answers 404 with the site's `404.html`.
- `api/frameworks`, `api/results/{slug}` and `api/host` answer exactly what the repository's
  `site/data/frameworks.json`, `results/{slug}.json` and `current.json` held at the commit
  published last.
- `logs/{profile}/{conns}/{name}.log` answers the log byte for byte, and 304 to its ETag.
- `api/ingest/` answers 401 without a key and 403 with a wrong one.
- Publishing the same commit twice changes nothing; a row the snapshot drops is removed, with a
  history entry that has no row.

## Against any address: read only

    node tests/smoke.mjs https://http-arena.genhttp.run/

It only reads, so it is safe against the live lambda.

## Everything, against a local run

The writes are checked against `dotnet run` on a machine with the repository, never against the
live lambda. The platform's files (`Program.cs`, the `.csproj`, `Platform/`) come from a clone of
the lambda:

    git clone <the lambda's git address> run && cp -r site/lambda/. run/
    python3 scripts/gen_leaderboard_data.py
    scripts/assemble_site.sh --no-logs /tmp/site && cp -r /tmp/site/. run/resources/
    cd run && ARENA_INGEST_KEY=test dotnet run          # http://localhost:8080/

Then publish to it as the workflow does, twice - the second run must send nothing and say the
publish is unchanged:

    ARENA_URL=http://localhost:8080 ARENA_INGEST_KEY=test python3 scripts/publish_genhttp.py --skip site

and compare what it answers with the files: every `api/results/{slug}` against
`site/data/results/{slug}.json`, every log against `site/static/logs/`.
