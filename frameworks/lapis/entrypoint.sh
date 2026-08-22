#!/bin/sh
# The harness mounts /certs only for the TLS profiles, and nginx will not start
# with an ssl_certificate pointing at an absent file, so the json-tls server
# block is added only when the certificate is actually there.
set -e
if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
    cp /app/json-tls.conf /app/tls.d/
fi
exec openresty -p /app -c /app/nginx.conf -g "daemon off;"
