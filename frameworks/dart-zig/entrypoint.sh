#!/bin/sh
set -eu

PORT="${PORT:-8080}"
WORKERS="${WORKERS:-$(nproc)}"
MODE="${DART_ZIG_MODE:-aot}"
CLUSTER="${DART_ZIG_CLUSTER:-1}"
export LD_LIBRARY_PATH=/opt/dart-zig/lib

if [ "$MODE" = "aot" ]; then
  BIN="/opt/dart-zig/bin/dart-zig-aot"
  SNAP="/app/benchmark_http_server_aot.so"
else
  BIN="/opt/dart-zig/bin/dart-zig"
  SNAP="/app/benchmark_http_server.dill"
fi

echo "[dart-zig] mode=${MODE} workers=${WORKERS} cluster=${CLUSTER} port=${PORT}"

# Default mode: one process, runtime-managed worker threads.
if [ "$CLUSTER" != "1" ] || [ "${WORKERS}" -le 1 ]; then
  exec "$BIN" --workers="$WORKERS" "$SNAP" "$PORT"
fi

# Cluster mode: one OS process per worker, each with --workers=1.
# Runtime bind path sets SO_REUSEPORT so listeners can share the same port.
i=1
while [ "$i" -lt "${WORKERS}" ]; do
  "$BIN" --workers=1 "$SNAP" "$PORT" &
  i=$((i + 1))
done

exec "$BIN" --workers=1 "$SNAP" "$PORT"
