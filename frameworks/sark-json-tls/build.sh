#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
docker build -t httparena-sark-json-tls \
    --build-arg BIN=httparena-sark-json-tls \
    -f "$SCRIPT_DIR/../sark/Dockerfile" "$SCRIPT_DIR/../sark"
