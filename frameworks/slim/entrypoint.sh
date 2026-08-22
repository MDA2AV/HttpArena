#!/bin/sh
# The harness mounts /certs only for the TLS profiles. Caddy will not start with
# a tls directive pointing at absent files, so the json-tls site is added only
# when the certificate is actually there.
set -e
if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
    cp /etc/caddy/json-tls.caddy /etc/caddy/tls.d/
fi
exec frankenphp run --config /etc/caddy/Caddyfile --adapter caddyfile
