#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
docker build -t httparena-cardigan \
    --build-arg CARDIGAN_HTTPARENA_MODE=h1 \
    "$SCRIPT_DIR"
