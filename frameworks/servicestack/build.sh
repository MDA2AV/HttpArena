#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
docker build -t httparena-servicestack -f "$SCRIPT_DIR/Dockerfile" "$ROOT_DIR"
