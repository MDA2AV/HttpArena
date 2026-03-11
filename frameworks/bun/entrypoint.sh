#!/bin/sh
CPUS=$(nproc)
for i in $(seq 1 "$CPUS"); do
  bun run /app/server.ts &
done
wait
