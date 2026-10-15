#!/usr/bin/env bash
# Lays out the site that gets served, from what scripts/gen_leaderboard_data.py generated:
# without the run logs for the genhttp.dev lambda (publish_genhttp.py), which sends the site's
# log links on to the logs in this repository instead, and with them in site/public/ to look
# at the whole site locally (python3 -m http.server -d site/public).
#
#   scripts/assemble_site.sh [--no-logs] [out-dir]     out-dir defaults to site/public
set -euo pipefail

logs=1
if [ "${1:-}" = "--no-logs" ]; then logs=0; shift; fi

site="$(cd "$(dirname "$0")/../site" && pwd)"
out="${1:-$site/public}"
case "$out" in ""|/) echo "assemble_site.sh: refusing to lay the site out in '$out'" >&2; exit 1 ;; esac

rm -rf "$out" && mkdir -p "$out"
out="$(cd "$out" && pwd)"    # absolute, before leaving for site/
cd "$site"

cp generated/index.html "$out/index.html"                                  # the board with its default view pre-rendered into #rows (leaderboard/index.html is the source)
cp leaderboard/data.js "$out/data.js"
cp leaderboard/search.js "$out/search.js"                                   # plain-text Knowledge Base index for the board's page search
if [ "$logs" = 1 ]; then cp -r static/logs "$out/logs"; fi                  # run logs, served at /logs/
for f in openapi.json openapi-gateway.json; do [ -f "static/$f" ] && cp "static/$f" "$out/$f"; done   # OpenAPI specs linked from the docs
cp -r root/. "$out/"                                                        # 404.html, robots.txt, favicon.ico/.svg, and the /leaderboard/ -> / redirect
cp -r generated/docs "$out/docs"                                            # pre-rendered Knowledge Base pages (real /docs/<id>/ URLs) + docs.css
cp generated/sitemap.xml "$out/sitemap.xml"                                 # root + every /docs/<id>/ (generated, replaces the old static one)
cp -r generated/badge "$out/badge"                                          # shields.io endpoints behind the README badges, /badge/<fw>/<family>.json
cp -r generated/frameworks "$out/frameworks"                                # a real page per entry at /frameworks/<slug>/, plus the index over them
cp -r generated/compare "$out/compare"                                      # head-to-head pages, one per language, at /compare/<language>/
cp generated/data.json "$out/data.json"                                     # every result as plain JSON: what the Dataset structured data points at
cp generated/llms.txt generated/llms-full.txt "$out/"                       # the ranking and the Knowledge Base as text, for readers that never run JS
if [ -f generated/og.png ]; then cp generated/og.png "$out/og.png"; fi      # social card for the board; the per-doc ones ride along inside generated/docs
