#!/usr/bin/env bash
# paozhu has one plaintext and one TLS port per process. HttpArena needs four
# listeners, so run two instances with two conf files: the main one serves
# :8080 (HTTP/1.1) and :8443 (ALPN h2), the second serves :8081 with ALPN
# pinned to http/1.1 for json-tls plus :8082 cleartext h2c for json-h2c.
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

    # Bash parameter substitution, not sed: passwords may contain '&', '\'
    # or '/', all of which are special in a sed replacement.
    while IFS= read -r line; do
        line="${line//__DB_HOST__/$db_host}"
        line="${line//__DB_PORT__/$db_port}"
        line="${line//__DB_NAME__/$db_name}"
        line="${line//__DB_USER__/$db_user}"
        line="${line//__DB_PASSWORD__/$db_password}"
        line="${line//__DB_MAX_CONN__/$db_max}"
        printf '%s\n' "$line"
    done < /app/conf/orm.conf.tpl > /app/conf/main/orm.conf
fi

# No /app/conf/server.conf exists, so httpserver::run() falls back to argv[1]
# and each instance loads its own ports (8080/8443 vs 8082/8081).
/server /app/conf/h1/server.conf &
H1_PID=$!
/server /app/conf/main/server.conf &
MAIN_PID=$!

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
