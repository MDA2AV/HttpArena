#!/usr/bin/env bash
# HttpArena framework validation — orchestrator.
#
# The suite lives in scripts/lib/validate/ and is sourced (not executed) in the
# order below, so every module shares one shell: globals, the cleanup trap, the
# PASS/FAIL counters, and the check_* helpers are all visible across modules.
#
#   setup.sh      args, globals, cleanup trap, watchdog, meta parse, has_test
#   build.sh      build the framework image (skipped for gateway-only entries)
#   container.sh  volume mounts, Postgres/Redis sidecars, container start, readiness
#   assert.sh     DOCS_BASE, check helpers (check/check_status/...), wait_h2,
#                 check_static_freshness
#   checks/*.sh   per-profile validation blocks, each guarded by has_test
#   summary.sh    print "Results: N passed, M failed" and set the exit code
#
# Run from the repo root:  ./scripts/validate.sh <framework>
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <framework>" >&2
    exit 2
fi

VALIDATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/validate"

source "$VALIDATE_LIB/setup.sh"
source "$VALIDATE_LIB/build.sh"
source "$VALIDATE_LIB/container.sh"
source "$VALIDATE_LIB/assert.sh"

# Per-profile checks, sourced in the original execution order. Each module runs
# only the blocks whose tests the framework subscribes to (has_test guards).
for _check_module in connection json upload http2 static database websocket gateway; do
    source "$VALIDATE_LIB/checks/$_check_module.sh"
done

source "$VALIDATE_LIB/summary.sh"
