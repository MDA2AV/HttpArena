# Tests

## What has to keep working

- The site: `/` is the board, a folder answers with its `index.html` (`docs/scoring/`), a folder
  without its slash is sent on to it (`docs` answers 301 to `docs/`), and a path that is nothing
  answers 404 with the site's `404.html`. Every page answers exactly what `assemble_site.sh` laid
  out at the commit `api/site` names.
- Publishing the same site twice sends nothing the second time; content no longer named by the
  site or the one before it is deleted.
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
    cd run && ARENA_INGEST_KEY=test dotnet run          # http://localhost:8080/, no site yet

Then generate the site and publish to it as the workflow does, but for the code, twice - the
second run must send nothing and say each publish is unchanged:

    python3 scripts/gen_leaderboard_data.py
    ARENA_URL=http://localhost:8080 ARENA_INGEST_KEY=test python3 scripts/publish_genhttp.py --skip code

and compare what it answers with the files: every page against `scripts/assemble_site.sh
--no-logs`, every `api/results/{slug}` against `site/data/results/{slug}.json`, every log against
`site/static/logs/`.
