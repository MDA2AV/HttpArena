# scripts/lib/validate/setup.sh — args, globals, cleanup trap, watchdog, meta parse, has_test
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.

#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK="$1"
IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-validate-${FRAMEWORK}"
PORT=8080
H2PORT=8443
H1TLS_PORT=8081
H2C_PORT=8082
PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
CERTS_DIR="$ROOT_DIR/certs"
DATA_DIR="$ROOT_DIR/data"

PG_CONTAINER="httparena-validate-postgres"
PG_NETWORK="httparena-validate-net"

cleanup() {
    # Kill watchdog if still running
    [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    # Restore any static files the freshness probe mutated (in case it aborted).
    if [ -n "${STATIC_FRESH_BACKUP:-}" ] && [ -d "${STATIC_FRESH_BACKUP:-}" ]; then
        for _b in "$STATIC_FRESH_BACKUP"/*; do
            [ -e "$_b" ] && cp -f "$_b" "$DATA_DIR/static/$(basename "$_b")" 2>/dev/null || true
        done
        rm -rf "$STATIC_FRESH_BACKUP" 2>/dev/null || true
        STATIC_FRESH_BACKUP=""
    fi
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    # Stop any multi-container compose stacks that may be running.
    # Each profile has its own compose file + project namespace.
    local cp_profile cp_compose
    for cp_profile in gateway-64 gateway-h3 production-stack; do
        if [ "$cp_profile" = "gateway-64" ]; then
            cp_compose="$ROOT_DIR/frameworks/$FRAMEWORK/compose.gateway.yml"
        else
            cp_compose="$ROOT_DIR/frameworks/$FRAMEWORK/compose.$cp_profile.yml"
        fi
        if [ -f "$cp_compose" ]; then
            CERTS_DIR="${CERTS_DIR:-$ROOT_DIR/certs}" DATA_DIR="${DATA_DIR:-$ROOT_DIR/data}" DATABASE_URL="${DATABASE_URL:-}" \
                docker compose -f "$cp_compose" -p "httparena-validate-gw-${cp_profile}-${FRAMEWORK}" down --remove-orphans 2>/dev/null || true
        fi
    done
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker network rm "$PG_NETWORK" 2>/dev/null || true
}
trap cleanup EXIT

# 5-minute overall timeout
VALIDATE_TIMEOUT=${VALIDATE_TIMEOUT:-300}
( trap 'exit 0' TERM; sleep "$VALIDATE_TIMEOUT"; echo ""; echo "FAIL: Validation timed out after ${VALIDATE_TIMEOUT}s"; kill -TERM $$ 2>/dev/null ) &
WATCHDOG_PID=$!

echo "=== Validating: $FRAMEWORK ==="

# Read subscribed tests from meta.json
if [ ! -f "$META_FILE" ]; then
    echo "SKIP: meta.json not found (framework removed)"
    exit 0
fi
TESTS=$(python3 -c "import json; print(' '.join(json.load(open('$META_FILE'))['tests']))")
echo "[info] Subscribed tests: $TESTS"

# Type/mode drive the static freshness probe (engine/infrastructure are exempt).
FW_TYPE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('type',''))" 2>/dev/null || echo "")
FW_MODE=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('mode','standard'))" 2>/dev/null || echo "standard")
STATIC_FRESH_BACKUP=""   # set by check_static_freshness; restored by cleanup() on exit

has_test() {
    # Exact whole-token match. `grep -qw` treats "-" as a word boundary
    # and matches "baseline" against "baseline-h2c" / "baseline-h2", and
    # "json" against "json-h2c" / "json-tls" / "json-comp" — all false
    # positives. Bash pattern match on the space-padded string is exact.
    [[ " $TESTS " == *" $1 "* ]]
}


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
