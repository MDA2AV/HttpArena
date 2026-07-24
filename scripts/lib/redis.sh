# scripts/lib/redis.sh — Redis sidecar for profiles that need a shared
# cross-process cache. Currently used by the crud profile so multi-process
# frameworks (hono-bun, workerman, etc.) can present a unified cache to
# requests load-balanced across their SO_REUSEPORT workers.
#
# Pinned to 1 physical core + its SMT sibling (`0,64` on this box) so
# Redis cost shows up in a separate CPU budget rather than stealing from
# the framework server's cpuset.

REDIS_CONTAINER="httparena-redis"
REDIS_URL="redis://localhost:6379"
REDIS_CPUSET="${REDIS_CPUSET:-0,64}"

redis_start() {
    info "starting redis sidecar (cpuset=$REDIS_CPUSET)"

    docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true

    docker run -d --rm --name "$REDIS_CONTAINER" --network host \
        --cpuset-cpus="$REDIS_CPUSET" \
        --ulimit memlock=-1:-1 \
        --ulimit nofile=1048576:1048576 \
        redis:7-alpine \
        redis-server \
            --protected-mode no \
            --bind 0.0.0.0 \
            --port 6379 \
            --save "" \
            --appendonly no \
            --maxmemory 512mb \
            --maxmemory-policy allkeys-lru \
            --io-threads 1 \
            >/dev/null

    # Wait for PING to succeed.
    local i
    for i in $(seq 1 30); do
        if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
            info "redis ready"
            return 0
        fi
        sleep 0.5
    done
    fail "redis sidecar did not become ready within 15s"
}

redis_stop() {
    docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
}
