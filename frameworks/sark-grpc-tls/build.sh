#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
docker build -t httparena-sark-grpc-tls \
    --build-arg GRPC_TLS=1 \
    -f "$SCRIPT_DIR/../sark-grpc/Dockerfile" "$SCRIPT_DIR/../sark"
