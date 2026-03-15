#!/bin/sh
# Multi-process launcher: one worker per CPU core with SO_REUSEPORT
NPROC=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

if [ "$NPROC" -le 1 ]; then
  exec /app/server
fi

PIDS=""
cleanup() {
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null
  done
  wait
  exit 0
}
trap cleanup INT TERM

i=0
while [ "$i" -lt "$NPROC" ]; do
  /app/server &
  PIDS="$PIDS $!"
  i=$((i + 1))
done

wait
