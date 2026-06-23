#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
docker build -t httparena-sark-grpc \
    -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/../sark"
