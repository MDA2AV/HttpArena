#!/bin/sh
# lwan reads its listeners and limits from lwan.conf.
#
# No tls_listener: lwan's TLS is Linux kTLS with an mbedTLS *1.2* handshake
# (ENABLE_TLS, off by default upstream), and the json-tls profile requires
# TLS 1.3 — validate.sh fails anything lower. So this entry does not subscribe
# to json-tls and serves plaintext only.
set -e

cat > /app/lwan.conf <<'EOF'
listener *:8080

# The upload profile posts bodies of up to 20 MB; the default cap is 10x the
# 4 KB request buffer, which answers "Request too large".
max_post_data_size = 25165824
max_put_data_size = 25165824

site {
    &baseline11 /baseline11
    &json_items /json/
    &upload /upload
}
EOF

cd /app
exec /server
