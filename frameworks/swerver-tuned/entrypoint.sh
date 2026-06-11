#!/bin/bash
set -e

# Database profiles (async-db, fortunes) run over plaintext HTTP/1.1 and the
# harness provides connection details via DATABASE_URL. swerver reads Postgres
# from its config file (and takes the password from an env var, never the URL),
# so inject a postgres block into the h1 config when DATABASE_URL is set. Absent
# DATABASE_URL (all non-DB profiles), the client stays disabled.
if [ -n "${DATABASE_URL:-}" ]; then
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -E 's#^[a-z]+://[^:/]+:([^@]+)@.*#\1#')
    export PGPASSWORD
    pg_base=$(echo "$DATABASE_URL" | sed -E 's#^([a-z]+://[^:/]+):[^@]+@#\1@#; s#\?.*##')
    pg_url="${pg_base}?sslmode=disable"
    jq --arg url "$pg_url" \
        '.postgres = {url: $url, password_env: "PGPASSWORD", pool_size_per_worker: 4}' \
        /etc/swerver/config-h1.json > /tmp/config-h1.json && mv /tmp/config-h1.json /etc/swerver/config-h1.json
    echo "entrypoint: postgres enabled for h1 ($pg_url)"
fi

# Start the h1 instance FIRST. When it serves the DB profiles, let its PG
# pools connect while h1 is the only process running — before the other three
# protocol instances start and saturate the (often 2-4) CPUs of a CI runner.
# Connect + SCRAM-handshake work needs CPU; with the full 4-instance x nproc
# footprint already competing, a freshly-warming worker is starved and the
# first DB request 503s (NotConnected). Warming the pool in the clear first
# avoids that without lowering worker counts.
/usr/local/bin/swerver --config /etc/swerver/config-h1.json &
H1_PID=$!

if [ -n "${DATABASE_URL:-}" ]; then
    # Wait until the PG pool is serving (async-db 200), bounded ~10s so a
    # missing DB can't hang startup, and short enough that the other
    # instances are up before the harness reaches the h2/h3 profiles.
    for i in $(seq 1 40); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
            "http://localhost:8080/async-db?min=10&max=50&limit=1" 2>/dev/null || echo 000)
        if [ "$code" = "200" ]; then
            echo "entrypoint: h1 PG pool warm after ${i} poll(s)"
            break
        fi
        sleep 0.25
    done
fi

/usr/local/bin/swerver --config /etc/swerver/config-h2c.json &
H2C_PID=$!

/usr/local/bin/swerver --config /etc/swerver/config-tls.json &
TLS_PID=$!

/usr/local/bin/swerver --config /etc/swerver/config-tls-h1.json &
TLS_H1_PID=$!

shutdown() {
    kill "$H1_PID" "$H2C_PID" "$TLS_PID" "$TLS_H1_PID" 2>/dev/null || true
    wait "$H1_PID" 2>/dev/null || true
    wait "$H2C_PID" 2>/dev/null || true
    wait "$TLS_PID" 2>/dev/null || true
    wait "$TLS_H1_PID" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

wait -n "$H1_PID" "$H2C_PID" "$TLS_PID" "$TLS_H1_PID"
shutdown
exit 1
