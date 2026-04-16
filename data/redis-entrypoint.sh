#!/bin/sh
# Redis entrypoint for the production-stack cache container.
# Starts redis-server, waits for it to become ready, seeds the known-state
# dataset from /seed.txt (session tokens + user JSON + product JSON), and
# then foregrounds redis-server so the container stays alive.
#
# Pre-seeding means the benchmark measures steady-state warm-cache throughput,
# not cold-start behavior. Every /api/* request in the workload hits a
# pre-populated key set up by this script.

set -e

redis-server \
    --daemonize no \
    --protected-mode no \
    --bind 0.0.0.0 \
    --port 6379 \
    --io-threads 4 \
    --io-threads-do-reads yes \
    --save "" \
    --appendonly no &
REDIS_PID=$!

# Wait for Redis to be ready (usually <100 ms).
for _ in $(seq 1 50); do
    if redis-cli PING 2>/dev/null | grep -q PONG; then
        break
    fi
    sleep 0.1
done

if [ -f /seed.txt ]; then
    redis-cli < /seed.txt > /dev/null
    echo "[redis] seeded from /seed.txt"
else
    echo "[redis] WARNING: /seed.txt not found, running empty"
fi

# Hand back to Redis as the foreground process.
wait "$REDIS_PID"
