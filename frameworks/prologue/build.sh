#!/bin/bash
TAG="${1:-httparena-prologue}"
docker build --network host -t "$TAG" -f "$(dirname "$0")/Dockerfile" "$(dirname "$0")"
