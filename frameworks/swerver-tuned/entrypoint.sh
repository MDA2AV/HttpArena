#!/bin/bash
set -e

# ONE swerver process serves all four protocol ports via its multi-listener
# config (8080 h1, 8082 h2c-only, 8081 TLS h1, 8443 TLS h2 + QUIC h3). A single
# process with the normal nproc workers — no 4-instance × nproc CPU
# over-subscription, which previously flaked the DB/TLS profiles under
# un-pinned validation.

# Database profiles (async-db, fortunes) run over plaintext HTTP/1.1 and the
# harness provides connection details via DATABASE_URL. swerver reads Postgres
# from its config file (and takes the password from an env var, never the URL),
# so inject a postgres block when DATABASE_URL is set. Absent DATABASE_URL (all
# non-DB profiles), the client stays disabled.
if [ -n "${DATABASE_URL:-}" ]; then
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -E 's#^[a-z]+://[^:/]+:([^@]+)@.*#\1#')
    export PGPASSWORD
    pg_base=$(echo "$DATABASE_URL" | sed -E 's#^([a-z]+://[^:/]+):[^@]+@#\1@#; s#\?.*##')
    pg_url="${pg_base}?sslmode=disable"
    jq --arg url "$pg_url" \
        '.postgres = {url: $url, password_env: "PGPASSWORD", pool_size_per_worker: 4}' \
        /etc/swerver/config-multi.json > /tmp/config-multi.json && mv /tmp/config-multi.json /etc/swerver/config-multi.json
    echo "entrypoint: postgres enabled ($pg_url)"
fi

/usr/local/bin/swerver --config /etc/swerver/config-multi.json &
SRV_PID=$!

if [ -n "${DATABASE_URL:-}" ]; then
    # Warm every worker's PG pool before the harness starts hitting async-db.
    # Each worker is a SO_REUSEPORT shard with its own pool; a single 200 only
    # proves the one worker that accepted it. Each curl is a fresh connection,
    # so the kernel spreads them across workers — poll until a run of
    # consecutive 200s (high confidence all pools are ready). Bounded (~120
    # polls) so a missing DB can't hang startup.
    streak=0; need=25
    for i in $(seq 1 120); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
            "http://localhost:8080/async-db?min=10&max=50&limit=1" 2>/dev/null || echo 000)
        if [ "$code" = "200" ]; then
            streak=$((streak + 1))
            if [ "$streak" -ge "$need" ]; then
                echo "entrypoint: PG pools warm ($need consecutive, after $i polls)"
                break
            fi
        else
            streak=0
            sleep 0.1
        fi
    done
fi

shutdown() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

wait "$SRV_PID"
shutdown
exit 1
