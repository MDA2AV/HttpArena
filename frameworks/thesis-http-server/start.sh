#!/bin/sh
set -eu
workers=${THESIS_WORKERS:-$(nproc)}
case "$workers" in ''|*[!0-9]*|0) exit 2 ;; esac
pids=''
shutdown() {
    trap - TERM INT
    kill -TERM $pids 2>/dev/null || true
    wait
}
trap 'shutdown; exit 0' TERM INT
while [ "$workers" -gt 0 ]; do
    php -d memory_limit=320M -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=128M server.php &
    pids="$pids $!"
    workers=$((workers - 1))
done
wait -n || true
shutdown
exit 1
