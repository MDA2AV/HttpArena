#!/usr/bin/env bash
# One paozhu process owns all four listeners from comma-separated httpport and
# httpsport values: :8080 HTTP/1.1, :8443 TLS, :8081 TLS for json-tls and :8082
# cleartext h2c for baseline-h2c and json-h2c. See README.md.
set -euo pipefail

cd /app

# serverconfig resolves TLS file names relative to server.conf, so stage the
# harness pair into the single conf directory.
if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
    cp /certs/server.crt /app/conf/server.crt
    cp /certs/server.key /app/conf/server.key
    chmod 600 /app/conf/server.key
fi

http_ioc_count() {
    local key value item first last quota period quota_cpus
    local allowed=""
    local count=0
    local -a ranges

    if [ -r /proc/self/status ]; then
        while IFS=: read -r key value; do
            if [ "$key" = "Cpus_allowed_list" ]; then
                allowed="$value"
                break
            fi
        done < /proc/self/status
    fi
    if [ -z "$allowed" ] && [ -r /sys/devices/system/cpu/online ]; then
        read -r allowed < /sys/devices/system/cpu/online || true
    fi
    if [ -z "$allowed" ]; then
        allowed=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
        if [[ "$allowed" =~ ^[0-9]+$ ]] && [ "$allowed" -gt 0 ]; then
            allowed="0-$((allowed - 1))"
        fi
    fi

    IFS=, read -r -a ranges <<< "$allowed"
    for item in "${ranges[@]}"; do
        item="${item//[[:space:]]/}"
        if [[ "$item" == *-* ]]; then
            first="${item%-*}"
            last="${item#*-}"
        else
            first="$item"
            last="$item"
        fi
        if [[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]]; then
            count=$((count + last - first + 1))
        fi
    done
    if [ "$count" -lt 1 ]; then count=1; fi

    quota_cpus=0
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        if read -r quota period < /sys/fs/cgroup/cpu.max; then
            if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] &&
               [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
                quota_cpus=$(((quota + period - 1) / period))
            fi
        fi
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] &&
         [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        quota=""
        period=""
        read -r quota < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true
        read -r period < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true
        if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] &&
           [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
            quota_cpus=$(((quota + period - 1) / period))
        fi
    fi
    if [ "$quota_cpus" -gt 0 ] && [ "$quota_cpus" -lt "$count" ]; then
        count=$quota_cpus
    fi
    printf '%s\n' "$count"
}

# HttpArena injects DATABASE_URL / DATABASE_MAX_CONN only for the DB profiles.
# startup_orm_init() unconditionally reads <conf dir>/orm.conf, so render
# src/conf/orm.conf beside server.conf from the environment instead of shipping
# hardcoded credentials.
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
    if [ "$db_max" -gt 256 ]; then db_max=256; fi
    # The DB profiles only SELECT and the edit pool has maxpool=0/minpool=0,
    # so the full budget belongs to the select pool.
    db_select_max=$db_max
    http_iocs=$(http_ioc_count)
    co_cap=0
    ioc_cap=4
    if [ -r /app/conf/server.conf ]; then
        while IFS='=' read -r key value; do
            key="${key//[[:space:]]/}"
            value="${value%%;*}"
            value="${value//[[:space:]]/}"
            if [ "$key" = "cothreadnum" ] && [[ "$value" =~ ^[0-9]+$ ]]; then
                co_cap=$value
            elif [ "$key" = "ioc_thread_num" ] && [[ "$value" =~ ^[0-9]+$ ]]; then
                ioc_cap=$value
                if [ "$ioc_cap" -lt 1 ]; then ioc_cap=1; fi
            fi
        done < /app/conf/server.conf
    fi
    if [ "$co_cap" -gt 0 ] && [ "$co_cap" -lt "$http_iocs" ]; then
        http_iocs=$co_cap
    fi
    if [ "$http_iocs" -lt 4 ]; then http_iocs=4; fi
    if [ "$http_iocs" -gt "$ioc_cap" ]; then http_iocs=$ioc_cap; fi
    db_select_min=$((db_select_max / http_iocs))
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
    done < /app/conf/orm.conf.tpl > /app/conf/orm.conf
fi

/server /app/conf/server.conf &
SERVER_PID=$!

shutdown() {
    trap - TERM INT
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}
trap shutdown TERM INT

# ── Lazy-cache warmup ────────────────────────────────────────────────────
# arena.cpp 懒加载静态文件：首次 miss 时把存在的源文件/.gz/.br 变体全部
# 读入全局 hash 表缓存。预热一次后 h2load 进来全部 hit，零 fopen/fread。
# Accept-Encoding 与 h2load 一致（br;q=1, gzip;q=0.8），让预热 curl 本身
# 也走 br 命中路径。
wait_ready() {
    local url="$1" i
    for i in $(seq 1 120); do
        if curl -sf --max-time 2 -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}
warm_static() {
    local base="$1" f n
    for f in /data/static/*; do
        case "$f" in *.br|*.gz) continue ;; esac
        [ -f "$f" ] || continue
        n="${f##*/}"
        curl -sf --max-time 5 \
             -H 'Accept-Encoding: br;q=1, gzip;q=0.8' \
             "$base/static/$n" -o /dev/null 2>/dev/null || true
    done
}
if [ -d /data/static ]; then
    # Readiness probe hits /pipeline so it does not touch the static cache;
    # warm_static below is what loads the file variants.
    wait_ready http://localhost:8080/pipeline || true
    warm_static http://localhost:8080
    warm_static http://localhost:8082
fi

wait "$SERVER_PID" || true
shutdown
