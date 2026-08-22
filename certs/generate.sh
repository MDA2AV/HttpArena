#!/usr/bin/env bash
# Regenerates the self-signed certificate the TLS profiles use.
#
# The subjectAltName matters: a certificate with only a CN is not valid to
# anything that follows RFC 9525, which dropped CN fallback entirely, and some
# server libraries parse the extension while loading and fail outright when it
# is missing rather than at verification time. Every TLS profile connects to
# localhost, so that plus the loopback addresses is what has to be covered.
set -euo pipefail
cd "$(dirname "$0")"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server.key -out server.crt \
    -days 3650 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1,IP:0.0.0.0,IP:::1" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"

chmod 644 server.crt server.key
openssl x509 -in server.crt -noout -subject -ext subjectAltName -dates
