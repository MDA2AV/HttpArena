#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HTT_ARENA_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
FRAMEWORK_IMAGE="httparena-dart-zig"
RUNTIME_IMAGE="${DART_ZIG_RUNTIME_IMAGE:-ghcr.io/kartikey321/dart-zig-runtime:latest}"
BUILDER_IMAGE="${DART_ZIG_BUILDER_IMAGE:-ghcr.io/kartikey321/dart-zig-builder:latest}"
USE_LOCAL_BUNDLE="${DART_ZIG_USE_LOCAL_BUNDLE:-0}"
LOCAL_RUNTIME_IMAGE="${DART_ZIG_LOCAL_RUNTIME_IMAGE:-dart-zig-runtime:local}"
LOCAL_BUILDER_IMAGE="${DART_ZIG_LOCAL_BUILDER_IMAGE:-dart-zig-builder:local}"
APP_SOURCE="$SCRIPT_DIR/benchmark_http_server.dart"
DATASET_SOURCE="$HTT_ARENA_ROOT/data/dataset.json"

build_framework_image() {
  docker build \
    -f "$SCRIPT_DIR/Dockerfile" \
    --build-arg BASE_IMAGE="$1" \
    --build-arg BUILDER_IMAGE="$2" \
    -t "$FRAMEWORK_IMAGE" \
    "$HTT_ARENA_ROOT"
}

[[ -f "$APP_SOURCE" ]] || {
  echo "missing benchmark app source: $APP_SOURCE" >&2
  exit 1
}
[[ -f "$DATASET_SOURCE" ]] || {
  echo "missing dataset: $DATASET_SOURCE" >&2
  exit 1
}

if [[ "$USE_LOCAL_BUNDLE" != "1" ]]; then
  docker pull "$RUNTIME_IMAGE"
  docker pull "$BUILDER_IMAGE"
  build_framework_image "$RUNTIME_IMAGE" "$BUILDER_IMAGE"
  exit 0
fi

: "${DART_ZIG_SDK_ROOT:?set DART_ZIG_SDK_ROOT when DART_ZIG_USE_LOCAL_BUNDLE=1}"
PKG_SCRIPT="$DART_ZIG_SDK_ROOT/dart-zig/scripts/package_runtime_bundle.sh"
RUNTIME_DOCKERFILE="$DART_ZIG_SDK_ROOT/dart-zig/docker/Dockerfile.runtime-base"
BUILDER_DOCKERFILE="$DART_ZIG_SDK_ROOT/dart-zig/docker/Dockerfile.builder-base"
BUNDLE_CONTEXT="$DART_ZIG_SDK_ROOT/dart-zig/dist"

[[ -x "$PKG_SCRIPT" ]] || { echo "missing package script: $PKG_SCRIPT" >&2; exit 1; }
[[ -f "$RUNTIME_DOCKERFILE" ]] || { echo "missing runtime Dockerfile: $RUNTIME_DOCKERFILE" >&2; exit 1; }
[[ -f "$BUILDER_DOCKERFILE" ]] || { echo "missing builder Dockerfile: $BUILDER_DOCKERFILE" >&2; exit 1; }

"$PKG_SCRIPT"
docker build -f "$RUNTIME_DOCKERFILE" -t "$LOCAL_RUNTIME_IMAGE" "$BUNDLE_CONTEXT"
docker build -f "$BUILDER_DOCKERFILE" -t "$LOCAL_BUILDER_IMAGE" "$DART_ZIG_SDK_ROOT"
build_framework_image "$LOCAL_RUNTIME_IMAGE" "$LOCAL_BUILDER_IMAGE"
