#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# Expose the host's local maven repository to the build so mavenLocal()
# can resolve locally published (e.g. SNAPSHOT) Ktor artifacts.
M2_REPO="${M2_REPO:-$HOME/.m2/repository}"

args=(-t httparena-ktor)
if [ -d "$M2_REPO" ]; then
    args+=(--build-context "m2=$M2_REPO")
fi

docker build "${args[@]}" "$SCRIPT_DIR"
