# scripts/lib/framework.sh — framework container lifecycle and meta.json
# reading. One framework runs many profiles; we build the image once then
# start/stop a fresh container per (profile, conn_count) iteration.

# Metadata populated by framework_load_meta().
FRAMEWORK=""
IMAGE_NAME=""
CONTAINER_NAME=""
LANGUAGE=""
DISPLAY_NAME=""
FRAMEWORK_TESTS=""

# ── Metadata loading ────────────────────────────────────────────────────────

framework_load_meta() {
    FRAMEWORK="$1"
    IMAGE_NAME="httparena-${FRAMEWORK}"
    CONTAINER_NAME="httparena-bench-${FRAMEWORK}"

    local meta_file="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
    [ -f "$meta_file" ] || fail "$meta_file not found"

    LANGUAGE=$(python3 -c "
import json; print(json.load(open('$meta_file')).get('language', ''))" 2>/dev/null || echo "")

    DISPLAY_NAME=$(python3 -c "
import json; print(json.load(open('$meta_file')).get('display_name', '$FRAMEWORK'))" 2>/dev/null || echo "$FRAMEWORK")

    FRAMEWORK_TESTS=$(python3 -c "
import json; print(','.join(json.load(open('$meta_file')).get('tests', [])))" 2>/dev/null || echo "")

    info "framework: $FRAMEWORK ($DISPLAY_NAME, $LANGUAGE)"
    info "subscribed tests: $FRAMEWORK_TESTS"
}

framework_subscribes_to() {
    local profile="$1"
    [ -z "$FRAMEWORK_TESTS" ] && return 0
    echo ",$FRAMEWORK_TESTS," | grep -qF ",$profile,"
}

# ── Image build ─────────────────────────────────────────────────────────────

framework_build() {
    info "building image: $IMAGE_NAME"
    local build_script="frameworks/$FRAMEWORK/build.sh"
    if [ -x "$build_script" ]; then
        "$build_script" || fail "$build_script exited non-zero"
    else
        docker build -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" \
            || fail "docker build failed"
    fi
}

# ── Container lifecycle ─────────────────────────────────────────────────────

# Start a framework container with volume mounts appropriate to the endpoint.
# Arguments: $1 = endpoint, $2 = optional cpuset|cpu count limit.
framework_start() {
    local endpoint="$1"
    local cpu_limit="${2:-}"

    docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
    docker rm   -f  "$CONTAINER_NAME" 2>/dev/null || true

    local args=(
        -d --name "$CONTAINER_NAME" --network host
        --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1
        --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE"
        -v "$DATA_DIR/dataset.json:/data/dataset.json:ro"
        -v "$DATA_DIR/static:/data/static:ro"
        -v "$CERTS_DIR:/certs:ro"
    )

    # Profiles that exercise the database get DATABASE_URL + per-profile conn cap.
    case "$endpoint" in
        async-db|api-4|api-16)
            args+=(-e "DATABASE_URL=$DATABASE_URL" -e "DATABASE_MAX_CONN=256")
            ;;
    esac

    # api-4 / api-16 additionally cap memory.
    case "$endpoint" in
        api-4)  args+=(--memory=16g --memory-swap=16g) ;;
        api-16) args+=(--memory=32g --memory-swap=32g) ;;
    esac

    # Profile-declared CPU limit.
    if [ -n "$cpu_limit" ]; then
        if [[ "$cpu_limit" == *-* ]]; then
            args+=(--cpuset-cpus="$cpu_limit")
        else
            local avail
            avail=$(nproc 2>/dev/null || echo 64)
            if [ "$cpu_limit" -gt "$avail" ] 2>/dev/null; then
                warn "profile asks for $cpu_limit CPUs, only $avail available — capping"
                cpu_limit="$avail"
            fi
            args+=(--cpus="$cpu_limit")
        fi
    fi

    docker run "${args[@]}" "$IMAGE_NAME" >/dev/null
}

framework_stop() {
    docker stop -t 5  "$CONTAINER_NAME" 2>/dev/null || true
    # -v nukes any anonymous volumes the framework image declared (e.g.
    # postgres-style VOLUME directives in a Dockerfile). Without it the
    # volume lingers on every benchmark cycle and silently fills disk.
    docker rm   -f -v "$CONTAINER_NAME" 2>/dev/null || true
}

# ── Readiness probe ─────────────────────────────────────────────────────────

# Block until the server responds, or fail after N seconds. Uses the right
# probe for each endpoint type.
framework_wait_ready() {
    local endpoint="$1"
    local probe_url

    info "waiting for server..."

    case "$endpoint" in
        grpc|grpc-tls|grpc-stream|grpc-stream-tls)
            _wait_grpc "$endpoint" && return 0
            ;;
        h3|static-h3)
            probe_url="https://localhost:$H2PORT/baseline2?a=1&b=1"
            ;;
        h2|baseline-h2)
            probe_url="https://localhost:$H2PORT/baseline2?a=1&b=1"
            ;;
        static-h2)
            probe_url="https://localhost:$H2PORT/static/reset.css"
            ;;
        static)
            probe_url="http://localhost:$PORT/static/reset.css"
            ;;
        json)
            probe_url="http://localhost:$PORT/json/1"
            ;;
        json-tls)
            probe_url="https://localhost:$H1TLS_PORT/json/1?m=1"
            ;;
        ws-echo)
            probe_url="http://localhost:$PORT/ws"
            ;;
        *)
            probe_url="http://localhost:$PORT/baseline11?a=1&b=1"
            ;;
    esac

    local i
    for i in $(seq 1 30); do
        if curl -sk -o /dev/null --max-time 2 "$probe_url" 2>/dev/null; then
            info "server ready"
            return 0
        fi
        sleep 1
    done
    return 1
}

_wait_grpc() {
    local endpoint="$1"
    local target flag
    if [[ "$endpoint" == *-tls ]]; then
        target="localhost:$H2PORT"
        flag="--skipTLS"
    else
        target="localhost:$PORT"
        flag="--insecure"
    fi
    local proto="$REQUESTS_DIR/benchmark.proto"
    [ -f "$proto" ] || proto=$(find "$ROOT_DIR/frameworks/$FRAMEWORK" -name benchmark.proto -type f | head -1)

    local i
    for i in $(seq 1 30); do
        if "$GHZ" "$flag" --proto "$proto" \
             --call benchmark.BenchmarkService/GetSum \
             -d '{"a":1,"b":2}' -c 1 -n 1 "$target" >/dev/null 2>&1; then
            info "gRPC server ready"
            return 0
        fi
        sleep 1
    done
    return 1
}
