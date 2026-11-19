#!/usr/bin/env bash
# benchmark-lite.sh — benchmark.sh with the "lite" host profile
# (scripts/lib/hosts/lite.sh), for local development.
#
# Usage:
#   ./scripts/benchmark-lite.sh                     # every enabled framework
#   ./scripts/benchmark-lite.sh <framework>         # one framework, all profiles
#   ./scripts/benchmark-lite.sh <framework> <profile[,profile...]>
#   ./scripts/benchmark-lite.sh <framework> --save  # keep results in results-hosts/lite/
#   ./scripts/benchmark-lite.sh --load-threads 4 <framework>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARGS=()
LOAD_THREADS=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --save)              ARGS+=(--save) ;;
        --load-threads)      LOAD_THREADS="$2"; shift ;;
        --load-threads=*)    LOAD_THREADS="${1#*=}" ;;
        *)                   POSITIONAL+=("$1") ;;
    esac
    shift
done

export HOST_PROFILE=lite
LITE_THREADS="${LOAD_THREADS:-${THREADS:-}}"
export LITE_THREADS

FRAMEWORK_ARG="${POSITIONAL[0]:-}"
[ -n "${POSITIONAL[1]:-}" ] && ARGS=("${POSITIONAL[1]}" "${ARGS[@]+"${ARGS[@]}"}")

if [ -n "$FRAMEWORK_ARG" ]; then
    exec "$SCRIPT_DIR/benchmark.sh" "$FRAMEWORK_ARG" "${ARGS[@]+"${ARGS[@]}"}"
fi

for fw_dir in "$ROOT_DIR"/frameworks/*/; do
    fw=$(basename "$fw_dir")
    enabled=$(python3 -c "import json; print(str(json.load(open('$fw_dir/meta.json')).get('enabled', True)).lower())" 2>/dev/null || echo true)
    if [ "$enabled" = "false" ]; then
        echo "[info] skip: $fw (disabled)"
        continue
    fi
    "$SCRIPT_DIR/benchmark.sh" "$fw" "${ARGS[@]+"${ARGS[@]}"}" || echo "[warn] $fw run failed, continuing"
done
