#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
docker build --no-cache -t httparena-effinitive -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"
