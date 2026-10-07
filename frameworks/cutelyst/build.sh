#!/usr/bin/env bash
# Optional wrapper so local re-runs can skip a full rebuild.
# HttpArena calls this when present (see scripts/lib/framework.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
IMAGE_NAME="${IMAGE_NAME:-httparena-cutelyst}"

if [[ "${SKIP_FRAMEWORK_BUILD:-0}" == "1" ]] \
    && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "[build] SKIP_FRAMEWORK_BUILD=1 — reusing existing $IMAGE_NAME"
  exit 0
fi

docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
