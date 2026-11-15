#!/usr/bin/env bash
# paozhu has one plaintext and one TLS port per process. HttpArena needs four
# listeners, so run two instances with two conf files: the main one serves
# :8080 (HTTP/1.1) and :8443 (ALPN h2), the second serves :8081 with ALPN
# pinned to http/1.1 for json-tls plus :8082 cleartext h2c for
# baseline-h2c and json-h2c.
# See README.md.
set -euo pipefail

cd /app

# serverconfig resolves the four TLS file names relative to each conf file's
# own directory, so stage the harness pair into both conf dirs.
if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
    for d in /app/conf/main /app/conf/h1; do
        cp /certs/server.crt "$d/server.crt"
        cp /certs/server.key "$d/server.key"
        chmod 600 "$d/server.key"
    done
fi

# HttpArena injects DATABASE_URL / DATABASE_MAX_CONN only for the DB profiles.
# startup_orm_init() unconditionally reads <conf dir>/orm.conf, so render
# src/conf/orm.conf into the main instance's conf dir from the environment
# instead of shipping hardcoded credentials. The h1 instance has no pool:
# /async-db and /fortunes are served on :8080 by the main instance.
if [ -n "${DATABASE_URL:-}" ]; then
    db_url="${DATABASE_URL#*://}"
    db_credentials="${db_url%%@*}"
    db_endpoint="${db_url#*@}"
    db_user="${db_credentials%%:*}"
    db_password="${db_credentials#*:}"
    db_host="${db_endpoint%%:*}"
    db_path="${db_endpoint#*:}"
    db_port="${db_path%%/*}"
    db_name="${db_path#*/}"
    db_name="${db_name%%\?*}"
    db_max="${DATABASE_MAX_CONN:-256}"
    case "$db_max" in ''|*[!0-9]*) db_max=256 ;; esac
    if [ "$db_max" -lt 8 ]; then db_max=8; fi
    if [ "$db_max" -gt 255 ]; then db_max=255; fi
    # The select pool IS the process-wide ceiling now (db.cpp has no gate):
    # cap it at db_max - 24 so 24 backends stay free for the edit pool,
    # readiness probes and PG maintenance. async_get_pg_select_conn() parks
    # and is woken on connection return once this quota is full.
    db_select_max=$(( db_max - 24 ))
    if [ "$db_select_max" -lt 1 ]; then db_select_max=$db_max; fi
    # Per-slot prebuild = ceil(select_max / 4 slots) so the resident set covers
    # the whole ceiling and a request never waits for a lazy connect.
    # 4 = orm_ioc_num in conf/main/server.conf.
    db_select_min=$(( (db_select_max + 3) / 4 ))
    if [ "$db_select_min" -lt 1 ]; then db_select_min=1; fi

    # Bash parameter substitution, not sed: passwords may contain '&', '\'
    # or '/', all of which are special in a sed replacement.
    while IFS= read -r line; do
        line="${line//__DB_HOST__/$db_host}"
        line="${line//__DB_PORT__/$db_port}"
        line="${line//__DB_NAME__/$db_name}"
        line="${line//__DB_USER__/$db_user}"
        line="${line//__DB_PASSWORD__/$db_password}"
        line="${line//__DB_SELECT_MAX__/$db_select_max}"
        line="${line//__DB_SELECT_MIN__/$db_select_min}"
        printf '%s\n' "$line"
    done < /app/conf/orm.conf.tpl > /app/conf/main/orm.conf
fi

# No /app/conf/server.conf exists, so httpserver::run() falls back to argv[1]
# and each instance loads its own ports (8080/8443 vs 8082/8081).
/server /app/conf/h1/server.conf &
H1_PID=$!
/server /app/conf/main/server.conf &
MAIN_PID=$!

# Pre-warm the native static compress cache. With the /static route removed and
# wwwpath=/data, the framework serves /data/static through its on-disk compress
# cache; hitting each identity file once (br preferred, as the benchmark sends)
# populates that cache before the benchmark instead of paying compression on the
# first live request. br is only produced on TLS, so warm via the HTTPS ports
# (8443 main, 8081 h1) — each instance has its own cache dir, so both must be
# warmed. Best-effort: a missed warm only means the first real request compresses
# once.
wait_ready() {
    local url="$1" i
    for i in $(seq 1 60); do
        if curl -sk --max-time 2 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}
warm_static() {
    local base="$1" f n
    for f in /data/static/*; do
        case "$f" in *.br|*.gz) continue ;; esac
        [ -f "$f" ] || continue
        n="${f##*/}"
        curl -sk --max-time 5 -H 'Accept-Encoding: br, gzip' "$base/static/$n" -o /dev/null 2>/dev/null || true
    done
}
if [ -d /data/static ]; then
    wait_ready https://localhost:8443/pipeline || true
    wait_ready https://localhost:8081/pipeline || true
    warm_static https://localhost:8443
    warm_static https://localhost:8081
fi

shutdown() {
    trap - TERM INT
    kill -TERM "$MAIN_PID" "$H1_PID" 2>/dev/null || true
    wait "$MAIN_PID" 2>/dev/null || true
    wait "$H1_PID" 2>/dev/null || true
}
trap shutdown TERM INT

# If either server exits, take the other one down too — the container should
# not look healthy with a dead listener.
wait -n "$MAIN_PID" "$H1_PID" || true
shutdown
