#!/usr/bin/env bash
set -euo pipefail

# Shared by the `proxygen` and `proxygen-coro` images; the binary is the same
# name in both, only the server API compiled into it differs.
#
# PROXYGEN_THREADS    TCP (H1/H2) I/O threads, 0 = available CPUs
# PROXYGEN_H3_THREADS QUIC I/O threads, 0 = available CPUs
exec /usr/local/bin/arena-server \
    --ip=:: \
    --http_port=8080 \
    --tls_port=8081 \
    --h2c_port=8082 \
    --h2_port=8443 \
    --h3_port=8443 \
    --cert=/certs/server.crt \
    --key=/certs/server.key \
    --threads="${PROXYGEN_THREADS:-0}" \
    --h3_threads="${PROXYGEN_H3_THREADS:-0}"
