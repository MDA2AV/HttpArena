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
    # Strip the password (swerver takes it from PGPASSWORD) and force IPv4:
    # getaddrinfo("localhost") returns ::1 first on IPv6-preferring hosts and
    # the sidecar may not accept there — 127.0.0.1 always works.
    pg_base=$(echo "$DATABASE_URL" | sed -E 's#^([a-z]+://[^:/]+):[^@]+@[^:/]+#\1@127.0.0.1#; s#\?.*##')
    pg_url="${pg_base}?sslmode=disable"

    # Scale the per-worker pool so workers × pool_size stays under Postgres'
    # max_connections. workers:0 means swerver runs `nproc` workers, each with
    # its OWN pool — on a big host (e.g. the self-hosted CI runner with ~128
    # threads) nproc×4 = 512 > the sidecar's 256, so most pools fail to connect
    # and DB requests routed (SO_REUSEPORT) to a starved worker 503 "database
    # not configured". Size pool = (max_conn − reserve) / nproc, clamped 1..4
    # (swerver rejects pool_size_per_worker > 4 — config.zig validateConfig).
    MAXC="${DATABASE_MAX_CONN:-256}"
    NCPU=$(nproc 2>/dev/null || echo 4)
    POOL=$(( (MAXC - 24) / NCPU ))
    [ "$POOL" -lt 1 ] && POOL=1
    [ "$POOL" -gt 4 ] && POOL=4

    jq --arg url "$pg_url" --argjson pool "$POOL" \
        '.postgres = {url: $url, password_env: "PGPASSWORD", pool_size_per_worker: $pool}' \
        /etc/swerver/config-multi.json > /tmp/config-multi.json && mv /tmp/config-multi.json /etc/swerver/config-multi.json
    echo "entrypoint: postgres enabled ($pg_url) pool_size_per_worker=$POOL (nproc=$NCPU, max_conn=$MAXC)"
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
            "http://127.0.0.1:8080/async-db?min=10&max=50&limit=1" 2>/dev/null || echo 000)
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
