#!/bin/bash
set -eu

workers="$(nproc)"
/server-h3 /certs/server.crt /certs/server.key 8443 "${workers}" /data/static &
h3_pid="$!"
/server &
server_pid="$!"

terminate() {
    kill "${h3_pid}" 2>/dev/null || true
    kill "${server_pid}" 2>/dev/null || true
}
trap terminate INT TERM EXIT

set +e
wait -n "${h3_pid}" "${server_pid}"
status="$?"
set -e
terminate
wait "${h3_pid}" 2>/dev/null || true
wait "${server_pid}" 2>/dev/null || true
exit "${status}"
