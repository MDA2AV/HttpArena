# HttpArena

The HttpArena website - the leaderboard of HTTP frameworks, its knowledge base and the log of
every benchmark run - together with the results behind it, which it also serves as an API. It
is meant to answer at www.http-arena.com.

## Who uses it, and for what

- **Visitors** compare frameworks on the board, read how each profile is measured, open an
  entry's page, or read the container log of a run that looks wrong.
- **README badges** across the frameworks' own repositories: shields.io reads
  `badge/{entry}/{family}.json` for the rank it draws.
- **The HttpArena repository** holds the results, and publishes here when its "Publish to
  genhttp.dev" workflow is run: the site and the results as of main, as data - no version is
  saved for them. Nothing is changed here by hand. The runs' logs stay in the repository.
- **Anyone who wants the numbers as data** reads `api/results`, `api/frameworks` and
  `api/history`, in the same shapes as the repository's `site/data/` files.

## What it does

- Serves the site exactly as the repository generated it at a commit of main.
- Keeps every published result, and how each changed from one publish to the next - so a
  result's history survives the repository overwriting it.
- Sends the address the site links a run's log from on to that log in the repository.

## What it does not do

- It is not where results or pages are edited: the repository is. This lambda serves what was
  published from it, and the next publish replaces anything changed here in the meantime.
- It does not run benchmarks or generate the site; the repository's scripts and workflows do.
