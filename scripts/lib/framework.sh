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

    framework_validate_tests
}

# A `tests` entry that doesn't name a real profile is otherwise silent:
# framework_subscribes_to() returns false, the driver logs "skip", and the
# framework quietly loses that coverage on every run since the typo landed.
# `php` lost json-tls to "json-lts" this way. Fail loudly instead.
#
# PROFILES comes from profiles.sh, which is sourced *after* this file — that's
# fine, the name resolves when this runs, not when the file is sourced.
framework_validate_tests() {
    local t unknown=()
    for t in ${FRAMEWORK_TESTS//,/ }; do
        [ -n "${PROFILES[$t]+x}" ] || unknown+=("$t")
    done
    [ ${#unknown[@]} -eq 0 ] || fail \
"$FRAMEWORK/meta.json subscribes to unknown profile(s): ${unknown[*]}
       known profiles: $(printf '%s\n' "${!PROFILES[@]}" | sort | tr '\n' ' ')"
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
        async-db|crud|fortunes)
            args+=(-e "DATABASE_URL=$DATABASE_URL" -e "DATABASE_MAX_CONN=256")
            ;;
    esac

    # crud also gets REDIS_URL so multi-process frameworks can use Redis as
    # their shared cross-process cache. Single-heap frameworks ignore it.
    case "$endpoint" in
        crud) args+=(-e "REDIS_URL=$REDIS_URL") ;;
    esac

    # Profile-declared CPU limit.
    if [ -n "$cpu_limit" ]; then
        if [[ "$cpu_limit" == *-* ]]; then
            local max_cpu
            max_cpu=$(($(nproc)-1))
            # Extract the largest CPU index from the cpuset string (e.g. "95" from "0-31,64-95")
            local requested_max
            requested_max=$(echo "$cpu_limit" | grep -oP '\d+$')
            
            if [ "$requested_max" -gt "$max_cpu" ]; then
                warn "profile cpuset $cpu_limit exceeds available CPUs (max $max_cpu) — using all cores"
                args+=(--cpus="$(nproc)")
            else
                args+=(--cpuset-cpus="$cpu_limit")
            fi
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
    local -a probe_extra=()

    # Pure-WebSocket frameworks (e.g. Fleck) don't speak HTTP at all, so the
    # curl probe below would never succeed. If every subscribed test is a
    # WS-only profile, sleep briefly to let the container bind its listener
    # (sub-second on most runtimes) and skip the HTTP probe.
    if [ -n "$FRAMEWORK_TESTS" ]; then
        local _t _all_ws=true
        IFS=',' read -ra _ws_tests_arr <<< "$FRAMEWORK_TESTS"
        for _t in "${_ws_tests_arr[@]}"; do
            case "$_t" in
                echo-ws|echo-ws-pipeline|echo-ws-limited) ;;
                *) _all_ws=false; break ;;
            esac
        done
        if $_all_ws; then
            info "ws-only framework — skipping HTTP probe (sleep 2s for startup)"
            sleep 2
            return 0
        fi
    fi

    info "waiting for server..."

    case "$endpoint" in
        grpc|grpc-tls)
            # Return the probe's own verdict. Falling through on failure lands
            # in the generic loop below, which reads $probe_url -- never set on
            # this path -- and dies with "unbound variable" under set -u,
            # hiding the real answer ("the gRPC server never became ready")
            # behind a shell error.
            _wait_grpc "$endpoint"
            return $?
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
        h2c|json-h2c)
            # h2c prior-knowledge — curl sends the h2 connection preface
            # immediately, no HTTP/1.1 Upgrade step. Server must speak h2c
            # on port 8082 or the probe fails.
            probe_url="http://localhost:$H2C_PORT/baseline2?a=1&b=1"
            probe_extra+=(--http2-prior-knowledge)
            ;;
        static)
            probe_url="http://localhost:$PORT/static/reset.css"
            ;;
        static-tls)
            probe_url="https://localhost:$H1TLS_PORT/static/reset.css"
            ;;
        json)
            probe_url="http://localhost:$PORT/json/1"
            ;;
        async)
            # Shortest delay the profile ever asks for, so readiness costs 10ms
            # rather than a tenth of the 2s curl budget.
            probe_url="http://localhost:$PORT/delay/10"
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
        if curl -sk -o /dev/null --max-time 2 "${probe_extra[@]}" "$probe_url" 2>/dev/null; then
            info "server ready"
            return 0
        fi
        sleep 1
    done
    return 1
}

_wait_grpc() {
    local endpoint="$1"
    local url proto_flag
    if [[ "$endpoint" == *-tls ]]; then
        url="https://localhost:$H2PORT/benchmark.BenchmarkService/GetSum"
        proto_flag="-k --http2"
    else
        url="http://localhost:$PORT/benchmark.BenchmarkService/GetSum"
        proto_flag="--http2-prior-knowledge"
    fi

    # A real unary GetSum, framed by hand rather than driven by a gRPC client.
    # ghz used to do this, and it was the only thing left needing that tool once
    # the streaming profiles went; a length-prefixed protobuf message is nine
    # bytes and costs no dependency at all.
    #
    #   00                 compressed-flag = 0
    #   00 00 00 04        big-endian message length
    #   08 01              field 1 (a) varint 1
    #   10 02              field 2 (b) varint 2
    local frame
    frame=$(mktemp)
    printf '\x00\x00\x00\x00\x04\x08\x01\x10\x02' > "$frame"

    local i head
    for i in $(seq 1 30); do
        # Ready means a gRPC answer, not merely an open socket: an h2 server
        # that has not registered the service yet still accepts connections.
        #
        # The verdict is the response *header* block -- 200 plus an
        # application/grpc content-type. grpc-status is deliberately not the
        # test: most servers (cardigan, and every grpc-go descendant) send it
        # as an HTTP/2 trailer, which -D does not capture, so requiring it
        # would hang the probe on servers that are perfectly ready. A non-gRPC
        # server on the same port answers 404 with text/plain and is rejected.
        head=$(curl -s --max-time 3 $proto_flag \
                    -H 'content-type: application/grpc' -H 'te: trailers' \
                    --data-binary "@$frame" -o /dev/null -D - "$url" 2>/dev/null)
        if grep -qiE '^HTTP/2 200' <<<"$head" \
           && grep -qi '^content-type: *application/grpc' <<<"$head"; then
            rm -f "$frame"
            info "gRPC server ready"
            return 0
        fi
        sleep 1
    done
    rm -f "$frame"
    return 1
}
