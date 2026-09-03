#!/usr/bin/env bash
# proxygen-coro reuses the proxygen build context and Dockerfile, selecting the
# coroutine server with --build-arg TARGET=coro (the sark-h3 -> sark pattern).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CONTEXT_DIR="$(cd "$SCRIPT_DIR/../proxygen" && pwd -P)"
docker build -t httparena-proxygen-coro \
    --build-arg TARGET=coro \
    -f "$CONTEXT_DIR/Dockerfile" \
    "$CONTEXT_DIR"
