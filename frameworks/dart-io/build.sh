#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HTT_ARENA_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
FRAMEWORK_IMAGE="httparena-dart-io"
BASE_IMAGE="${DART_IO_BASE_IMAGE:-dart:stable}"

docker pull "$BASE_IMAGE"
docker build \
  -f "$SCRIPT_DIR/Dockerfile" \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  -t "$FRAMEWORK_IMAGE" \
  "$HTT_ARENA_ROOT"
