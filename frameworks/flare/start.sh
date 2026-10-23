#!/bin/sh
# One flare process per listener: h1/ws/grpc-h2c :8080, h2c :8082, TLS h1/h2 :8443, QUIC h3 :8443.
export WORKERS=$(nproc)
MODE=plain PORT=8080 /app/bin/server &
MODE=plain PORT=8082 /app/bin/server &
MODE=tls PORT=8443 /app/bin/server &
MODE=h3 PORT=8443 /app/bin/server &
wait
