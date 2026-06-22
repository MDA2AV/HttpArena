#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
docker build -t httparena-sark-websocket \
    --build-arg BIN=httparena-sark-ws \
    -f "$SCRIPT_DIR/../sark/Dockerfile" "$SCRIPT_DIR/../sark"
