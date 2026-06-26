# scripts/lib/validate/container.sh — volume mounts, Postgres/Redis sidecars, container start, readiness wait
# Part of the validate.sh suite — sourced by scripts/validate.sh, not run directly.


# Mount volumes based on subscribed tests
HARD_NOFILE=$(ulimit -Hn 2>/dev/null || echo 1048576)
# Docker --ulimit nofile rejects "unlimited"; fall back to a large numeric cap
[[ "$HARD_NOFILE" =~ ^[0-9]+$ ]] || HARD_NOFILE=1048576
if has_test "async-db" || has_test "crud" || has_test "api-4" || has_test "api-16" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack" || has_test "fortunes"; then
    docker_args=(-d --name "$CONTAINER_NAME" --network host --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
else
    docker_args=(-d --name "$CONTAINER_NAME" -p "$PORT:8080" --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1 --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE")
fi
docker_args+=(-v "$DATA_DIR/dataset.json:/data/dataset.json:ro")

needs_h2=false
if has_test "baseline-h2" || has_test "static-h2" || has_test "baseline-h3" || has_test "static-h3" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack"; then
    needs_h2=true
fi

needs_h1tls=false
if has_test "json-tls"; then
    needs_h1tls=true
fi

needs_h2c=false
if has_test "baseline-h2c" || has_test "json-h2c"; then
    needs_h2c=true
fi

if ($needs_h2 || $needs_h1tls) && [ -d "$CERTS_DIR" ]; then
    docker_args+=(-v "$CERTS_DIR:/certs:ro")
    $needs_h2     && docker_args+=(-p "$H2PORT:8443")
    $needs_h1tls  && docker_args+=(-p "$H1TLS_PORT:8081")
fi

# h2c uses no TLS so no certs mount needed; just expose the port.
$needs_h2c && docker_args+=(-p "$H2C_PORT:8082")

if has_test "gateway-64" || has_test "gateway-h3"; then
    docker_args+=(-v "$DATA_DIR/dataset-large.json:/data/dataset-large.json:ro")
fi

if has_test "static" || has_test "static-h2" || has_test "static-h3" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack"; then
    docker_args+=(-v "$DATA_DIR/static:/data/static:ro")
fi

# Note: --security-opt seccomp=unconfined is applied unconditionally in both
# container-launch branches above. io_uring (and other syscalls some runtimes
# rely on) are blocked by Docker's default seccomp profile, and a framework
# shouldn't have to advertise engine=="io_uring" to be testable — many need it
# transitively (e.g. an engine built on io_uring under another name). This
# mirrors benchmark.sh, which always runs framework containers unconfined.

# Start Postgres sidecar if async-db is needed
if has_test "async-db" || has_test "crud" || has_test "api-4" || has_test "api-16" || has_test "gateway-64" || has_test "gateway-h3" || has_test "production-stack" || has_test "fortunes"; then
    echo "[postgres] Starting Postgres sidecar for validation..."
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    docker run -d --name "$PG_CONTAINER" --network host \
        -e POSTGRES_USER=bench \
        -e POSTGRES_PASSWORD=bench \
        -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:18 \
        -c max_connections=256
    for i in $(seq 1 60); do
        if docker exec "$PG_CONTAINER" pg_isready -U bench -d benchmark >/dev/null 2>&1; then
            # Ensure seed data is loaded (pg_isready fires before init scripts finish)
            if docker exec "$PG_CONTAINER" psql -U bench -d benchmark -tAc "SELECT 1 FROM items LIMIT 1" 2>/dev/null | grep -q 1; then
                echo "[postgres] Ready"
                break
            fi
        fi
        [ "$i" -eq 60 ] && { echo "FAIL: Postgres sidecar not ready"; exit 1; }
        sleep 1
    done
    docker_args+=(-e "DATABASE_URL=postgres://bench:bench@localhost:5432/benchmark")
    docker_args+=(-e "DATABASE_MAX_CONN=256")
fi

# Start Redis sidecar if needed
if has_test "crud"; then

    REDIS_CONTAINER="httparena-redis"
    REDIS_URL="redis://localhost:6379"
    # Validation is correctness-only, so the Redis sidecar is not pinned to specific
    # cores by default (benchmarking pins it via scripts/lib/redis.sh). Set REDIS_CPUSET
    # explicitly to restore pinning; left unset it runs unpinned and works on any host.
    REDIS_CPUSET="${REDIS_CPUSET:-}"

    echo "[redis] Starting Redis sidecar${REDIS_CPUSET:+ (cpuset=$REDIS_CPUSET)}"
    docker rm -f "$REDIS_CONTAINER" 2>/dev/null || true
    docker run -d --rm --name "$REDIS_CONTAINER" --network host \
        ${REDIS_CPUSET:+--cpuset-cpus="$REDIS_CPUSET"} \
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
    for i in $(seq 1 30); do
        if docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
            echo "[redis] Ready"
            break
        fi
        [ "$i" -eq 30 ] && { echo "FAIL: Redis sidecar not ready"; exit 1; }
        sleep 1
    done
    docker_args+=(-e "REDIS_URL=$REDIS_URL")
fi

# Start container (skip for gateway-only — compose handles it later)
if [ "$GATEWAY_ONLY" = "false" ]; then
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker run "${docker_args[@]}" "$IMAGE_NAME"

    # Wait for server to start.
    #
    # Primary probe is GET /baseline11 over plaintext HTTP/1.1 on $PORT — that
    # works for the vast majority of frameworks, which all listen on 8080.
    # H/2-only or H/3-only frameworks (e.g. wtx, which speaks h2c on 8080 or
    # h2/h3 on 8443 depending on build) never respond to an HTTP/1.1 request
    # and would otherwise time out. Fall back to GET /baseline2 over HTTPS
    # with ALPN h2 on $H2PORT when the framework subscribes to any h2 or h3
    # profile. H/3 servers still advertise h2 on the same TLS listener via
    # ALPN, so this single fallback covers both cases without requiring
    # curl to be built with HTTP/3 support.
    need_tls_probe=false
    if has_test "baseline-h2" || has_test "static-h2" \
       || has_test "baseline-h3" || has_test "static-h3"; then
        need_tls_probe=true
    fi

    need_h2c_probe=false
    if has_test "baseline-h2c" || has_test "json-h2c"; then
        need_h2c_probe=true
    fi

    # Pure-WebSocket frameworks (e.g. Fleck) don't speak HTTP at all, so the
    # curl probes below would never succeed. Skip the wait when every
    # subscribed test is a WS-only profile.
    _ws_only=true
    for _t in $TESTS; do
        case "$_t" in
            echo-ws|echo-ws-pipeline) ;;
            *) _ws_only=false; break ;;
        esac
    done
    if [ "$_ws_only" = "true" ] && [ -n "$TESTS" ]; then
        echo "[wait] ws-only framework — skipping readiness probe"
    else
        echo "[wait] Waiting for server..."
        for i in $(seq 1 30); do
            if curl -s --max-time 2 -o /dev/null -w '' "http://localhost:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
                break
            fi
            if [ "$need_tls_probe" = "true" ] && \
               curl -sk --http2 --max-time 2 -o /dev/null -w '' "https://localhost:$H2PORT/baseline2?a=1&b=1" 2>/dev/null; then
                break
            fi
            if [ "$need_h2c_probe" = "true" ] && \
               curl -s --http2-prior-knowledge --max-time 2 -o /dev/null -w '' "http://localhost:$H2C_PORT/baseline2?a=1&b=1" 2>/dev/null; then
                break
            fi
            if [ "$i" -eq 30 ]; then
                echo "FAIL: Server did not start within 30s"
                exit 1
            fi
            sleep 1
        done
        echo "[ready] Server is up"
    fi
fi


# keep `source` exit status 0 so the orchestrator continues (set -e stays active inside)
true
