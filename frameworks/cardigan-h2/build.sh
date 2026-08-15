#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CONTEXT_DIR="$(cd "$SCRIPT_DIR/../cardigan" && pwd -P)"
docker build -t httparena-cardigan-h2 \
    --build-arg CARDIGAN_HTTPARENA_MODE=h2 \
    "$CONTEXT_DIR"
