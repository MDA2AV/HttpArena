#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
docker build --network host -t httparena-kemal .
