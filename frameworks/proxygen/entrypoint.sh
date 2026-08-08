#!/usr/bin/env bash
set -euo pipefail

exec /usr/local/bin/proxygen-arena \
    --ip=:: \
    --http_port=8080 \
    --tls_port=8081 \
    --h2c_port=8082 \
    --h2_port=8443 \
    --h3_port=8443 \
    --cert=/certs/server.crt \
    --key=/certs/server.key \
    --threads="${PROXYGEN_THREADS:-0}"
