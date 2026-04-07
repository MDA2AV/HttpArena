#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

GCANNON="${GCANNON:-gcannon}"
GCANNON_IMAGE="${GCANNON_IMAGE:-gcannon:latest}"
GCANNON_CPUS="${GCANNON_CPUS:-32-63,96-127}"
GCANNON_MODE=native
H2LOAD="${H2LOAD:-h2load}"
OHA="${OHA:-$HOME/.cargo/bin/oha}"
GHZ="${GHZ:-ghz}"
HARD_NOFILE=$(ulimit -Hn)
ulimit -n "$HARD_NOFILE"
THREADS="${THREADS:-64}"
H2THREADS="${H2THREADS:-128}"
DURATION=5s
RUNS=3
PORT=8080
H2PORT=8443
REQUESTS_DIR="$ROOT_DIR/requests"
RESULTS_DIR="$ROOT_DIR/results"
CERTS_DIR="$ROOT_DIR/certs"

# Profile definitions: pipeline|req_per_conn|cpu_limit|connections|endpoint
# endpoint: empty = /baseline11 (raw), "json" = /json (GET), "compression" = /compression (GET+gzip), "pipeline" = /pipeline, "upload" = POST /upload (raw),
#           "h2" = /baseline2 (h2load), "static-h2" = multi-URI h2load, "h3" = /baseline2 (oha HTTP/3), "static-h3" = multi-URI oha,
#           "grpc" = gRPC unary (h2load h2c), "grpc-tls" = gRPC unary (h2load TLS),
#           "static" = multi-URI static files (gcannon --raw), "ws-echo" = WebSocket echo (gcannon --ws)
declare -A PROFILES=(
    [baseline]="1|0|0-31,64-95|512,4096|"
    [pipelined]="16|0|0-31,64-95|512,4096|pipeline"
    [limited-conn]="1|10|0-31,64-95|512,4096|"
    [json]="1|0|0-31,64-95|4096|json"
    [upload]="1|0|0-31,64-95|32,256|upload"
    [compression]="1|0|0-31,64-95|512,4096|compression"
    [noisy]="1|0|0-31,64-95|512,4096,16384|noisy"
    [api-4]="1|5|0-3|256|api-4"
    [api-16]="1|5|0-7,64-71|1024|api-16"
    [assets-4]="1|10|0-3|256|assets-4"
    [assets-16]="1|10|0-7,64-71|1024|assets-16"
    [static]="1|10|0-31,64-95|1024,4096,6800|static"
    [baseline-h2]="1|0|0-31,64-95|256,1024|h2"
    [static-h2]="1|0|0-31,64-95|256,1024|static-h2"
    [unary-grpc]="1|0|0-31,64-95|256,1024|grpc"
    [unary-grpc-tls]="1|0|0-31,64-95|256,1024|grpc-tls"
    [echo-ws]="1|0|0-31,64-95|512,4096,16384|ws-echo"
    [sync-db]="1|0|0-31,64-95|1024|sync-db"
    [async-db]="1|0|0-31,64-95|1024|async-db"
)
PROFILE_ORDER=(baseline pipelined limited-conn json upload compression noisy api-4 api-16 assets-4 assets-16 static sync-db async-db baseline-h2 static-h2 unary-grpc unary-grpc-tls echo-ws)

# Parse flags
SAVE_RESULTS=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --save) SAVE_RESULTS=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
FRAMEWORK="${POSITIONAL[0]:-}"
PROFILE_FILTER="${POSITIONAL[1]:-}"

rebuild_site_data() {
    local site_data="$ROOT_DIR/site/data"
    mkdir -p "$site_data"

    # Rebuild frameworks.json from individual meta.json files
    local fw_json="$site_data/frameworks.json"
    echo '{' > "$fw_json"
    local fw_first=true
    for fw_dir in "$ROOT_DIR"/frameworks/*/; do
        [ -d "$fw_dir" ] || continue
        local fw=$(basename "$fw_dir")
        local meta="$fw_dir/meta.json"
        [ -f "$meta" ] || continue
        $fw_first || echo ',' >> "$fw_json"
        local dn=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('display_name',sys.argv[2]))" "$meta" "$fw")
        local desc=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('description',''))" "$meta")
        local repo=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('repo',''))" "$meta")
        local ftype=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('type','realistic'))" "$meta")
        local engine=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('engine',''))" "$meta")
        printf '  "%s": {"dir": "%s", "description": "%s", "repo": "%s", "type": "%s", "engine": "%s"}' "$dn" "$fw" "$desc" "$repo" "$ftype" "$engine" >> "$fw_json"
        fw_first=false
    done
    echo '' >> "$fw_json"
    echo '}' >> "$fw_json"
    echo "[updated] site/data/frameworks.json"

    for profile_dir in "$RESULTS_DIR"/*/; do
        [ -d "$profile_dir" ] || continue
        local profile=$(basename "$profile_dir")
        for conn_dir in "$profile_dir"/*/; do
            [ -d "$conn_dir" ] || continue
            local conns=$(basename "$conn_dir")
            local data_file="$site_data/${profile}-${conns}.json"

            # Collect new framework names from results
            local new_fws=""
            for f in "$conn_dir"/*.json; do
                [ -f "$f" ] || continue
                local fw_name=$(basename "$f" .json)
                new_fws="$new_fws $fw_name"
            done

            # Merge: keep existing entries for frameworks NOT in new results, then add new ones
            python3 -c "
import json, sys, os, glob

data_file = sys.argv[1]
conn_dir = sys.argv[2]

# Build map of new results keyed by framework display name
new_entries = {}
for f in sorted(glob.glob(os.path.join(conn_dir, '*.json'))):
    try:
        entry = json.load(open(f))
        new_entries[entry.get('framework', '')] = entry
    except:
        pass

# Load existing data
existing = []
if os.path.exists(data_file):
    try:
        existing = json.load(open(data_file))
    except:
        existing = []

# Remove entries whose framework name matches any new result
merged = [e for e in existing if e.get('framework', '') not in new_entries]

# Add new results
merged.extend(new_entries.values())

# Deduplicate by framework name (keep highest RPS)
seen = {}
for e in merged:
    name = e.get('framework', '')
    if name not in seen or e.get('rps', 0) > seen[name].get('rps', 0):
        seen[name] = e
deduped = [seen[e.get('framework', '')] for e in merged if e.get('framework', '') in seen]
seen2 = set()
final = []
for e in deduped:
    name = e.get('framework', '')
    if name not in seen2:
        final.append(e)
        seen2.add(name)

final.sort(key=lambda e: e.get('framework', '').lower())

with open(data_file, 'w') as out:
    json.dump(final, out, indent=2)
" "$data_file" "$conn_dir"

            echo "[updated] site/data/${profile}-${conns}.json"
        done
    done

    # Write current round system info
    local cpu=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    local threads=$(nproc 2>/dev/null || echo "unknown")
    local threads_per_core=$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    local cores="$threads"
    if [ "$threads_per_core" -gt 0 ] 2>/dev/null; then
        cores=$((threads / threads_per_core))
    fi
    local ram=$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')
    local ram_speed=$(sudo dmidecode -t memory 2>/dev/null | awk '/Configured Memory Speed:/ && /MHz/ {print $4 " MHz"; exit}')
    [ -z "$ram_speed" ] && ram_speed="unknown"
    local governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    local os_info=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)
    local kernel=$(uname -r)
    local docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    local docker_runtime=$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo "unknown")
    local commit=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local lo_mtu=$(ip link show lo 2>/dev/null | awk '/mtu/ {print $5}')
    local cur_date=$(date +%Y-%m-%d)
    python3 -c "
import json, sys, subprocess

d = {'date': sys.argv[1], 'cpu': sys.argv[2], 'cores': sys.argv[3],
     'threads': sys.argv[15],
     'ram': sys.argv[4], 'os': sys.argv[5], 'kernel': sys.argv[6],
     'docker': sys.argv[7], 'commit': sys.argv[8],
     'governor': sys.argv[11], 'docker_runtime': sys.argv[12],
     'threads_per_core': sys.argv[13]}
rs = sys.argv[10]
if rs != 'unknown':
    d['ram_speed'] = rs

def sysctl(key):
    try:
        return subprocess.check_output(['sysctl', '-n', key], stderr=subprocess.DEVNULL).decode().strip()
    except:
        return None

tcp = {}
lo_mtu = sys.argv[14]
if lo_mtu:
    tcp['lo_mtu'] = lo_mtu
cc = sysctl('net.ipv4.tcp_congestion_control')
if cc:
    tcp['congestion'] = cc
somaxconn = sysctl('net.core.somaxconn')
if somaxconn:
    tcp['somaxconn'] = somaxconn
rmem = sysctl('net.core.rmem_max')
if rmem:
    tcp['rmem_max'] = rmem
wmem = sysctl('net.core.wmem_max')
if wmem:
    tcp['wmem_max'] = wmem

if tcp:
    d['tcp'] = tcp

with open(sys.argv[9], 'w') as f:
    json.dump(d, f, indent=2)
" "$cur_date" "$cpu" "$cores" "$ram" "$os_info" "$kernel" "$docker_ver" "$commit" "$site_data/current.json" "$ram_speed" "$governor" "$docker_runtime" "$threads_per_core" "$lo_mtu" "$threads"
    echo "[updated] site/data/current.json"
}

# If no framework, run all enabled ones
if [ -z "$FRAMEWORK" ]; then
    for fw_dir in "$ROOT_DIR"/frameworks/*/; do
        [ -d "$fw_dir" ] || continue
        fw=$(basename "$fw_dir")
        meta="$fw_dir/meta.json"

        # Check enabled flag (default true if not present)
        if [ -f "$meta" ]; then
            enabled=$(grep -oP '"enabled"\s*:\s*\K(true|false)' "$meta" 2>/dev/null || echo "true")
            if [ "$enabled" = "false" ]; then
                echo "[skip] $fw (disabled)"
                continue
            fi
        fi

        if [ "$SAVE_RESULTS" = "true" ]; then
            "$SCRIPT_DIR/benchmark.sh" "$fw" "$PROFILE_FILTER" --save || true
        else
            "$SCRIPT_DIR/benchmark.sh" "$fw" "$PROFILE_FILTER" || true
        fi
    done
    if [ "$SAVE_RESULTS" = "true" ]; then
        rebuild_site_data
    fi
    exit 0
fi

IMAGE_NAME="httparena-${FRAMEWORK}"
CONTAINER_NAME="httparena-bench-${FRAMEWORK}"

# Read metadata from framework meta.json
META_FILE="$ROOT_DIR/frameworks/$FRAMEWORK/meta.json"
LANGUAGE=""
DISPLAY_NAME="$FRAMEWORK"
FRAMEWORK_TESTS=""
if [ -f "$META_FILE" ]; then
    LANGUAGE=$(grep -oP '"language"\s*:\s*"\K[^"]+' "$META_FILE" 2>/dev/null || echo "")
    dn=$(grep -oP '"display_name"\s*:\s*"\K[^"]+' "$META_FILE" 2>/dev/null || echo "")
    [ -n "$dn" ] && DISPLAY_NAME="$dn"
    # Read tests array — extract as comma-separated list
    FRAMEWORK_TESTS=$(python3 -c "import json,sys; print(','.join(json.load(open(sys.argv[1])).get('tests',[])))" "$META_FILE" 2>/dev/null || echo "")

    # Check enabled
    enabled=$(grep -oP '"enabled"\s*:\s*\K(true|false)' "$META_FILE" 2>/dev/null || echo "true")
    if [ "$enabled" = "false" ]; then
        echo "[skip] $FRAMEWORK (disabled)"
        exit 0
    fi
fi

cleanup() {
    docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}

# Save original CPU governor
ORIG_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")

PG_CONTAINER="httparena-postgres"

restore_settings() {
    docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker stop -t 5 "$PG_CONTAINER" 2>/dev/null || true
    docker rm -f "$PG_CONTAINER" 2>/dev/null || true
    if [ -n "$ORIG_GOVERNOR" ]; then
        echo "[restore] Restoring CPU governor to $ORIG_GOVERNOR..."
        if command -v cpupower &>/dev/null; then
            sudo cpupower frequency-set -g "$ORIG_GOVERNOR" 2>/dev/null || true
        else
            for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                sudo sh -c "echo $ORIG_GOVERNOR > $g" 2>/dev/null || true
            done
        fi
    fi
}
trap restore_settings EXIT

# Clean slate: stop containers, remove postgres volume, restart Docker, drop caches
docker ps -q --filter "name=httparena-" | xargs -r docker stop -t 5 2>/dev/null || true
docker ps -aq --filter "name=httparena-" | xargs -r docker rm -f -v 2>/dev/null || true

AVAILABLE_CPUS=$(nproc 2>/dev/null || echo "64")
echo "[info] Available CPUs: $AVAILABLE_CPUS"

echo "[tune] Setting CPU governor to performance..."
if command -v cpupower &>/dev/null; then
    sudo cpupower frequency-set -g performance 2>/dev/null && echo "[tune] CPU governor set to performance" || echo "[warn] Could not set CPU governor (no sudo?). Results may vary."
else
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        sudo sh -c "echo performance > $g" 2>/dev/null || true
    done
    if [ $? -ne 0 ]; then
        echo "[warn] Could not set CPU governor. Results may vary."
    fi
fi

echo "[tune] Setting TCP accept queue for high connection counts..."
sudo sysctl -w net.core.somaxconn=65535 > /dev/null 2>&1 || echo "[warn] Could not set somaxconn (no sudo?)"
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65535 > /dev/null 2>&1 || true
sudo sysctl -w net.core.netdev_max_backlog=65535 > /dev/null 2>&1 || true

echo "[tune] Setting UDP buffer sizes for QUIC..."
sudo sysctl -w net.core.rmem_max=7500000 > /dev/null 2>&1 || true
sudo sysctl -w net.core.wmem_max=7500000 > /dev/null 2>&1 || true


echo "[clean] Restarting Docker daemon..."
if sudo systemctl restart docker 2>/dev/null; then
    sleep 3
else
    echo "[warn] Could not restart Docker (no sudo?). Skipping daemon restart."
fi
echo "[clean] Dropping kernel caches..."
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
sync

# Build once
echo "=== Building: $FRAMEWORK ==="
if [ -x "frameworks/$FRAMEWORK/build.sh" ]; then
    "frameworks/$FRAMEWORK/build.sh" || { echo "FAIL: build"; exit 1; }
else
    docker build -t "$IMAGE_NAME" "frameworks/$FRAMEWORK" || { echo "FAIL: build"; exit 1; }
fi

# Start Postgres sidecar if async-db is needed
if echo ",$FRAMEWORK_TESTS," | grep -qF ",async-db,"; then
    if [ -z "$PROFILE_FILTER" ] || [ "$PROFILE_FILTER" = "async-db" ] || [ "$PROFILE_FILTER" = "api-4" ] || [ "$PROFILE_FILTER" = "api-16" ]; then
        echo "[postgres] Starting Postgres sidecar..."
        docker rm -f "$PG_CONTAINER" 2>/dev/null || true
        docker run -d --name "$PG_CONTAINER" --network host \
            -e POSTGRES_USER=bench \
            -e POSTGRES_PASSWORD=bench \
            -e POSTGRES_DB=benchmark \
            -v "$ROOT_DIR/data/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
            postgres:17-alpine \
            -c max_connections=256
        for i in $(seq 1 60); do
            if docker exec "$PG_CONTAINER" pg_isready -U bench -d benchmark >/dev/null 2>&1; then
                if docker exec "$PG_CONTAINER" psql -U bench -d benchmark -tAc "SELECT 1 FROM items LIMIT 1" 2>/dev/null | grep -q 1; then
                    echo "[postgres] Ready (seeded)"
                    break
                fi
            fi
            [ "$i" -eq 60 ] && { echo "FAIL: Postgres did not start"; exit 1; }
            sleep 1
        done
    fi
fi

# Determine which profiles to run
if [ -n "$PROFILE_FILTER" ]; then
    profiles_to_run=("$PROFILE_FILTER")
else
    profiles_to_run=("${PROFILE_ORDER[@]}")
fi

for profile in "${profiles_to_run[@]}"; do
    # Check if framework subscribes to this test
    if [ -n "$FRAMEWORK_TESTS" ]; then
        if ! echo ",$FRAMEWORK_TESTS," | grep -qF ",$profile,"; then
            echo "[skip] $FRAMEWORK does not subscribe to $profile"
            continue
        fi
    fi

    if [ -n "${PROFILES[$profile]+x}" ]; then
        IFS='|' read -r pipeline req_per_conn cpu_limit conn_list endpoint <<< "${PROFILES[$profile]}"
    elif [ -n "${CUSTOM_PROFILE:-}" ]; then
        IFS='|' read -r pipeline req_per_conn cpu_limit conn_list endpoint <<< "$CUSTOM_PROFILE"
    else
        echo "[skip] Unknown profile: $profile"
        continue
    fi

    # Parse connection counts
    IFS=',' read -ra CONN_COUNTS <<< "$conn_list"

    for CONNS in "${CONN_COUNTS[@]}"; do

    echo ""
    echo "=============================================="
    echo "=== $FRAMEWORK / $profile / ${CONNS}c (p=$pipeline, r=${req_per_conn:-unlimited}, cpu=${cpu_limit:-unlimited}) ==="
    echo "=============================================="

    # (Re)start container with profile-specific flags
    docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    docker_args=(-d --name "$CONTAINER_NAME" --network host
        --security-opt seccomp=unconfined
        --ulimit memlock=-1:-1
        --ulimit nofile="$HARD_NOFILE:$HARD_NOFILE"
        -v "$ROOT_DIR/data/dataset.json:/data/dataset.json:ro"
        -v "$ROOT_DIR/data/dataset-large.json:/data/dataset-large.json:ro"
        -v "$ROOT_DIR/data/benchmark.db:/data/benchmark.db:ro"
        -v "$ROOT_DIR/data/static:/data/static:ro"
        -v "$CERTS_DIR:/certs:ro")
    if [ "$endpoint" = "async-db" ] || [ "$endpoint" = "api-4" ] || [ "$endpoint" = "api-16" ]; then
        docker_args+=(-e "DATABASE_URL=postgres://bench:bench@localhost:5432/benchmark")
        docker_args+=(-e "DATABASE_MAX_CONN=256")
    fi
    if [ "$endpoint" = "api-4" ] || [ "$endpoint" = "assets-4" ]; then
        docker_args+=(--memory=16g --memory-swap=16g)
    fi
    if [ "$endpoint" = "api-16" ] || [ "$endpoint" = "assets-16" ]; then
        docker_args+=(--memory=32g --memory-swap=32g)
    fi
    if [ -n "$cpu_limit" ]; then
        if [[ "$cpu_limit" == *-* ]]; then
            docker_args+=(--cpuset-cpus="$cpu_limit")
        else
            # Cap CPU limit to available cores
            if [ "$cpu_limit" -gt "$AVAILABLE_CPUS" ] 2>/dev/null; then
                echo "[warn] Profile requests ${cpu_limit} CPUs but only ${AVAILABLE_CPUS} available — capping to ${AVAILABLE_CPUS}"
                cpu_limit="$AVAILABLE_CPUS"
            fi
            docker_args+=(--cpus="$cpu_limit")
        fi
    fi
    docker run "${docker_args[@]}" "$IMAGE_NAME"

    # Wait for server
    echo "[wait] Waiting for server..."
    if [ "$endpoint" = "grpc" ] || [ "$endpoint" = "grpc-tls" ]; then
        PROTO_FILE=$(find "$ROOT_DIR/frameworks/$FRAMEWORK" -name 'benchmark.proto' -type f | head -1)
        if [ "$endpoint" = "grpc-tls" ]; then
            local_grpc_check="localhost:$H2PORT"
        else
            local_grpc_check="localhost:$PORT"
        fi
        for i in $(seq 1 30); do
            if $GHZ --insecure --proto "$PROTO_FILE" \
                --call benchmark.BenchmarkService/GetSum \
                -d '{"a":1,"b":2}' -c 1 -n 1 \
                "$local_grpc_check" >/dev/null 2>&1; then
                break
            fi
            if [ "$i" -eq 30 ]; then
                echo "FAIL: gRPC server did not start within 30s — skipping"
                docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
                docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
                continue 2
            fi
            sleep 1
        done
    else
        if [ "$endpoint" = "h3" ] || [ "$endpoint" = "static-h3" ]; then
            local_check_url="https://localhost:$H2PORT/baseline2?a=1&b=1"
        elif [ "$endpoint" = "h2" ] || [ "$endpoint" = "static-h2" ]; then
            local_check_url="https://localhost:$H2PORT/static/reset.css"
            [ "$endpoint" = "h2" ] && local_check_url="https://localhost:$H2PORT/baseline2?a=1&b=1"
        elif [ "$endpoint" = "upload" ]; then
            local_check_url="http://localhost:$PORT/baseline11?a=1&b=1"
        elif [ "$endpoint" = "noisy" ]; then
            local_check_url="http://localhost:$PORT/baseline11?a=1&b=1"
        elif [ "$endpoint" = "static" ]; then
            local_check_url="http://localhost:$PORT/static/reset.css"
        elif [ "$endpoint" = "json" ]; then
            local_check_url="http://localhost:$PORT/json"
        elif [ "$endpoint" = "ws-echo" ]; then
            local_check_url="http://localhost:$PORT/ws"
        else
            local_check_url="http://localhost:$PORT/baseline11?a=1&b=1"
        fi
        for i in $(seq 1 30); do
            if curl -sk -o /dev/null --max-time 2 "$local_check_url" 2>/dev/null; then
                break
            fi
            if [ "$i" -eq 30 ]; then
                echo "FAIL: Server did not start within 30s — skipping"
                docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
                docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
                continue 2
            fi
            sleep 1
        done
    fi
    echo "[ready] Server is up"

    # Build load generator args based on profile endpoint
    USE_H2LOAD=false
    USE_OHA=false
    if [ "$endpoint" = "ws-echo" ]; then
        gc_args=("http://localhost:$PORT/ws"
            --ws
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ "$endpoint" = "grpc" ]; then
        USE_H2LOAD=true
        gc_args=("$H2LOAD"
            "http://localhost:$PORT/benchmark.BenchmarkService/GetSum"
            -d "$REQUESTS_DIR/grpc-sum.bin"
            -H 'content-type: application/grpc'
            -H 'te: trailers'
            -c "$CONNS" -m 100 -t "$H2THREADS" -D "$DURATION")
    elif [ "$endpoint" = "grpc-tls" ]; then
        USE_H2LOAD=true
        gc_args=("$H2LOAD"
            "https://localhost:$H2PORT/benchmark.BenchmarkService/GetSum"
            -d "$REQUESTS_DIR/grpc-sum.bin"
            -H 'content-type: application/grpc'
            -H 'te: trailers'
            -c "$CONNS" -m 100 -t "$H2THREADS" -D "$DURATION")
    elif [ "$endpoint" = "static-h3" ]; then
        USE_OHA=true
        oha_out=$(mktemp)
        gc_args=("$OHA"
            "$REQUESTS_DIR/static-h2-uris.txt"
            --urls-from-file
            --http-version 3 --insecure
            -o "$oha_out" --output-format json
            -c "$CONNS" -p "$pipeline" -z "$DURATION")
    elif [ "$endpoint" = "h3" ]; then
        USE_OHA=true
        oha_out=$(mktemp)
        gc_args=("$OHA"
            "https://localhost:$H2PORT/baseline2?a=1&b=1"
            --http-version 3 --insecure
            -o "$oha_out" --output-format json
            -c "$CONNS" -p "$pipeline" -z "$DURATION")
    elif [ "$endpoint" = "static-h2" ]; then
        USE_H2LOAD=true
        gc_args=("$H2LOAD"
            -i "$REQUESTS_DIR/static-h2-uris.txt"
            -c "$CONNS" -m 100 -t "$H2THREADS" -D "$DURATION")
    elif [ "$endpoint" = "h2" ]; then
        USE_H2LOAD=true
        gc_args=("$H2LOAD"
            "https://localhost:$H2PORT/baseline2?a=1&b=1"
            -c "$CONNS" -m 100 -t "$H2THREADS" -D "$DURATION")
    elif [ "$endpoint" = "pipeline" ]; then
        gc_args=("http://localhost:$PORT/pipeline"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ "$endpoint" = "upload" ]; then
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/upload.raw"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ "$endpoint" = "compression" ]; then
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/json-gzip.raw"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ "$endpoint" = "api-4" ] || [ "$endpoint" = "api-16" ]; then
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/get.raw,$REQUESTS_DIR/get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/async-db-get.raw,$REQUESTS_DIR/async-db-get.raw"
            -c "$CONNS" -t 64 -d 15s -p "$pipeline")
    elif [ "$endpoint" = "assets-4" ] || [ "$endpoint" = "assets-16" ]; then
        # 20 templates: text+gzip(6), text-plain(6), binary+gzip(2), binary-plain(2), svg+gzip(1), svg-plain(1), json+gzip(1), json-plain(1)
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/static-app.js-gzip.raw,$REQUESTS_DIR/static-vendor.js-gzip.raw,$REQUESTS_DIR/static-components.css-gzip.raw,$REQUESTS_DIR/static-utilities.css-gzip.raw,$REQUESTS_DIR/static-header.html-gzip.raw,$REQUESTS_DIR/json-get-gzip.raw,$REQUESTS_DIR/static-router.js.raw,$REQUESTS_DIR/static-helpers.js.raw,$REQUESTS_DIR/static-layout.css.raw,$REQUESTS_DIR/static-theme.css.raw,$REQUESTS_DIR/static-footer.html.raw,$REQUESTS_DIR/json-get.raw,$REQUESTS_DIR/static-hero.webp-gzip.raw,$REQUESTS_DIR/static-regular.woff2-gzip.raw,$REQUESTS_DIR/static-thumb1.webp.raw,$REQUESTS_DIR/static-bold.woff2.raw,$REQUESTS_DIR/static-icon-sprite.svg-gzip.raw,$REQUESTS_DIR/static-logo.svg.raw,$REQUESTS_DIR/static-manifest.json.raw,$REQUESTS_DIR/static-reset.css.raw"
            -c "$CONNS" -t 64 -d 15s -p "$pipeline")
    elif [ "$endpoint" = "sync-db" ]; then
        gc_args=("http://localhost:$PORT/db?min=10&max=50"
            -c "$CONNS" -t "$THREADS" -d 10s -p "$pipeline")
    elif [ "$endpoint" = "async-db" ]; then
        gc_args=("http://localhost:$PORT/async-db?min=10&max=50"
            -c "$CONNS" -t "$THREADS" -d 10s -p "$pipeline")
    elif [ "$endpoint" = "noisy" ]; then
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/post_cl.raw,$REQUESTS_DIR/noise-badpath.raw,$REQUESTS_DIR/noise-badcl.raw,$REQUESTS_DIR/noise-binary.raw"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ "$endpoint" = "static" ]; then
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/static-reset.css.raw,$REQUESTS_DIR/static-layout.css.raw,$REQUESTS_DIR/static-theme.css.raw,$REQUESTS_DIR/static-components.css.raw,$REQUESTS_DIR/static-utilities.css.raw,$REQUESTS_DIR/static-analytics.js.raw,$REQUESTS_DIR/static-helpers.js.raw,$REQUESTS_DIR/static-app.js.raw,$REQUESTS_DIR/static-vendor.js.raw,$REQUESTS_DIR/static-router.js.raw,$REQUESTS_DIR/static-header.html.raw,$REQUESTS_DIR/static-footer.html.raw,$REQUESTS_DIR/static-regular.woff2.raw,$REQUESTS_DIR/static-bold.woff2.raw,$REQUESTS_DIR/static-logo.svg.raw,$REQUESTS_DIR/static-icon-sprite.svg.raw,$REQUESTS_DIR/static-hero.webp.raw,$REQUESTS_DIR/static-thumb1.webp.raw,$REQUESTS_DIR/static-thumb2.webp.raw,$REQUESTS_DIR/static-manifest.json.raw"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ "$endpoint" = "json" ]; then
        gc_args=("http://localhost:$PORT/json"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    elif [ -n "${CUSTOM_RAW:-}" ]; then
        gc_args=("http://localhost:$PORT"
            --raw "$CUSTOM_RAW"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    else
        gc_args=("http://localhost:$PORT"
            --raw "$REQUESTS_DIR/get.raw,$REQUESTS_DIR/post_cl.raw,$REQUESTS_DIR/post_chunked.raw"
            -c "$CONNS" -t "$THREADS" -d "$DURATION" -p "$pipeline")
    fi
    if [ "$USE_H2LOAD" = "false" ] && [ "$req_per_conn" -gt 0 ] 2>/dev/null; then
        gc_args+=(-r "$req_per_conn")
    fi

    # Best-of-N runs
    best_rps=0
    best_output=""
    best_cpu="0%"
    best_mem="0MiB"

    for run in $(seq 1 $RUNS); do
        echo ""
        echo "[run $run/$RUNS]"

        stats_log=$(mktemp)
        while true; do
            docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$CONTAINER_NAME" >> "$stats_log" 2>/dev/null
        done &
        stats_pid=$!

        if [ "$USE_OHA" = "true" ]; then
            timeout --foreground 45 "${gc_args[@]}" || true
            output=$(cat "$oha_out" 2>/dev/null)
            rm -f "$oha_out"
        elif [ "$USE_H2LOAD" = "true" ]; then
            output=$(timeout 45 "${gc_args[@]}" 2>&1) || true
        elif [ "$GCANNON_MODE" = "native" ]; then
            output=$(timeout 45 taskset -c "$GCANNON_CPUS" \
                env LD_LIBRARY_PATH=/usr/lib "$GCANNON" "${gc_args[@]}" 2>&1) || true
        else
            output=$(timeout 45 docker run --rm --network host \
                --cpuset-cpus="$GCANNON_CPUS" \
                --security-opt seccomp=unconfined \
                --ulimit memlock=-1:-1 \
                --ulimit nofile=1048576:1048576 \
                -v "$REQUESTS_DIR:$REQUESTS_DIR:ro" \
                "$GCANNON_IMAGE" "${gc_args[@]}" 2>&1) || true
        fi

        kill "$stats_pid" 2>/dev/null; wait "$stats_pid" 2>/dev/null || true

        avg_cpu=$(awk '{gsub(/%/,"",$1); if($1+0>0){sum+=$1; n++}} END{if(n>0) printf "%.1f%%", sum/n; else print "0%"}' "$stats_log")
        peak_mem=$(awk '{split($2,a,"/"); gsub(/[^0-9.]/,"",a[1]); unit=$2; gsub(/[0-9.]/,"",unit); if(a[1]+0>max){max=a[1]+0; u=unit}} END{if(max>0) printf "%.1f%s", max, u; else print "0MiB"}' "$stats_log")
        rm -f "$stats_log"

        echo "$output"
        echo "  CPU: $avg_cpu | Mem: $peak_mem"

        if [ "$USE_OHA" = "true" ]; then
            # oha JSON: .summary.requestsPerSec
            rps_int=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['summary']['requestsPerSec']))" 2>/dev/null || echo "0")
            rps_int=${rps_int:-0}
        elif [ "$USE_H2LOAD" = "true" ]; then
            # h2load: "finished in 5.00s, 123456.78 req/s, 45.67MB/s"
            rps_int=$(echo "$output" | grep -oP 'finished in [\d.]+s, \K[\d.]+' | cut -d. -f1 || echo "0")
            rps_int=${rps_int:-0}
        else
            duration_secs=$(echo "$output" | grep -oP 'requests in ([\d.]+)s' | grep -oP '[\d.]+' || echo "1")
            if [ "$endpoint" = "caching" ]; then
                run_ok=$(echo "$output" | grep -oP '3xx=\K\d+' || echo "0")
            else
                run_ok=$(echo "$output" | grep -oP '2xx=\K\d+' || echo "0")
            fi
            rps_int=$(echo "$run_ok / $duration_secs" | bc | cut -d. -f1)
            rps_int=${rps_int:-0}
        fi

        if [ "$rps_int" -gt "$best_rps" ]; then
            best_rps=$rps_int
            best_output="$output"
            best_cpu="$avg_cpu"
            best_mem="$peak_mem"
        fi

        sleep 2
    done

    echo ""
    echo "=== Best: ${best_rps} req/s (CPU: $best_cpu, Mem: $best_mem) ==="

    # Extract metrics
    if [ "$USE_OHA" = "true" ]; then
        # oha JSON: .summary.average (seconds), .latencyPercentiles.p99 (seconds)
        avg_lat=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d['summary']['average']; print(f'{v*1e6:.0f}us' if v<0.001 else f'{v*1000:.2f}ms')" 2>/dev/null || echo "—")
        p99_lat=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d['latencyPercentiles']['p99']; print(f'{v*1e6:.0f}us' if v<0.001 else f'{v*1000:.2f}ms')" 2>/dev/null || echo "—")
        reconnects="0"
        bandwidth=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d['summary']['sizePerSec']; print(f'{v/1024/1024:.2f}MB/s' if v>0 else '0')" 2>/dev/null || echo "0")
    elif [ "$USE_H2LOAD" = "true" ]; then
        # h2load: "time for request:  min  max  mean  sd  +/-sd" all on one line
        avg_lat=$(echo "$best_output" | awk '/time for request:/{print $6}')
        p99_lat="$avg_lat"  # h2load doesn't report p99; use mean as placeholder
        reconnects="0"
        bandwidth=$(echo "$best_output" | grep -oP 'finished in [\d.]+s, [\d.]+ req/s, \K[\d.]+[KMGT]?B/s' || echo "0")
    else
        avg_lat=$(echo "$best_output" | grep "Latency" | head -1 | awk '{print $2}')
        p99_lat=$(echo "$best_output" | grep "Latency" | head -1 | awk '{print $5}')
        reconnects=$(echo "$best_output" | grep -oP 'Reconnects: \K\d+' || echo "0")
        bandwidth=$(echo "$best_output" | grep -oP 'Bandwidth:\s+\K\S+' || echo "0")
    fi

    # Extract status codes
    status_2xx=0; status_3xx=0; status_4xx=0; status_5xx=0
    if [ "$USE_OHA" = "true" ]; then
        status_2xx=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin).get('statusCodeDistribution',{}); print(sum(v for k,v in d.items() if 200<=int(k)<300))" 2>/dev/null || echo "0")
        status_3xx=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin).get('statusCodeDistribution',{}); print(sum(v for k,v in d.items() if 300<=int(k)<400))" 2>/dev/null || echo "0")
        status_4xx=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin).get('statusCodeDistribution',{}); print(sum(v for k,v in d.items() if 400<=int(k)<500))" 2>/dev/null || echo "0")
        status_5xx=$(echo "$best_output" | python3 -c "import sys,json; d=json.load(sys.stdin).get('statusCodeDistribution',{}); print(sum(v for k,v in d.items() if 500<=int(k)<600))" 2>/dev/null || echo "0")
    elif [ "$USE_H2LOAD" = "true" ]; then
        status_2xx=$(echo "$best_output" | grep -oP '\d+(?= 2xx)' || echo "0")
        status_3xx=$(echo "$best_output" | grep -oP '\d+(?= 3xx)' || echo "0")
        status_4xx=$(echo "$best_output" | grep -oP '\d+(?= 4xx)' || echo "0")
        status_5xx=$(echo "$best_output" | grep -oP '\d+(?= 5xx)' || echo "0")
    else
        status_2xx=$(echo "$best_output" | grep -oP '2xx=\K\d+' || echo "0")
        status_3xx=$(echo "$best_output" | grep -oP '3xx=\K\d+' || echo "0")
        status_4xx=$(echo "$best_output" | grep -oP '4xx=\K\d+' || echo "0")
        status_5xx=$(echo "$best_output" | grep -oP '5xx=\K\d+' || echo "0")
    fi

    # Compute input bandwidth from raw template sizes × RPS
    input_bw=""
    if [ "$USE_H2LOAD" = "false" ] && [ "$USE_OHA" = "false" ]; then
        raw_arg=""
        prev_was_raw=false
        for arg in "${gc_args[@]}"; do
            if [ "$prev_was_raw" = "true" ]; then
                raw_arg="$arg"
                break
            fi
            [ "$arg" = "--raw" ] && prev_was_raw=true || prev_was_raw=false
        done
        if [ -n "$raw_arg" ]; then
            avg_tpl_size=$(IFS=','; total=0; count=0; for f in $raw_arg; do s=$(wc -c < "$f" 2>/dev/null); total=$((total + s)); count=$((count + 1)); done; echo "$((total / count))")
            input_bw=$(python3 -c "
bps = $best_rps * $avg_tpl_size
if bps >= 1073741824: print(f'{bps/1073741824:.2f}GB/s')
elif bps >= 1048576: print(f'{bps/1048576:.2f}MB/s')
elif bps >= 1024: print(f'{bps/1024:.2f}KB/s')
else: print(f'{bps}B/s')
" 2>/dev/null || echo "")
        fi
    fi

    if [ -n "$input_bw" ]; then
        echo "  Input BW: $input_bw (avg template: ${avg_tpl_size} bytes)"
    fi

    # Parse per-template response counts (gcannon mixed/multi-template output)
    tpl_json=""
    if [ "$USE_H2LOAD" = "false" ] && [ "$USE_OHA" = "false" ]; then
        tpl_line=$(echo "$best_output" | grep -oP 'Per-template-ok: \K.*' || echo "")
        if [ -n "$tpl_line" ] && ([ "$endpoint" = "api-4" ] || [ "$endpoint" = "api-16" ]); then
            # API-4 templates: get×3, json-get×3, async-db×2
            IFS=',' read -ra tpl_counts <<< "$tpl_line"
            t_baseline=$(( ${tpl_counts[0]:-0} + ${tpl_counts[1]:-0} + ${tpl_counts[2]:-0} ))
            t_json=$(( ${tpl_counts[3]:-0} + ${tpl_counts[4]:-0} + ${tpl_counts[5]:-0} ))
            t_async_db=$(( ${tpl_counts[6]:-0} + ${tpl_counts[7]:-0} ))
            tpl_json=",
  \"tpl_baseline\": $t_baseline,
  \"tpl_json\": $t_json,
  \"tpl_db\": 0,
  \"tpl_upload\": 0,
  \"tpl_compression\": 0,
  \"tpl_static\": 0,
  \"tpl_async_db\": $t_async_db"
        fi
        if [ -n "$tpl_line" ] && ([ "$endpoint" = "assets-4" ] || [ "$endpoint" = "assets-16" ]); then
            # assets-4/16 templates (20): text-gzip(5)+json-gzip(1), text-plain(5)+json-plain(1), binary-gzip(2), binary-plain(2), svg-gzip(1), svg-plain(1), manifest(1), reset.css(1)
            IFS=',' read -ra tpl_counts <<< "$tpl_line"
            t_static_gzip=$(( ${tpl_counts[0]:-0} + ${tpl_counts[1]:-0} + ${tpl_counts[2]:-0} + ${tpl_counts[3]:-0} + ${tpl_counts[4]:-0} ))
            t_json_gzip=$(( ${tpl_counts[5]:-0} ))
            t_static_plain=$(( ${tpl_counts[6]:-0} + ${tpl_counts[7]:-0} + ${tpl_counts[8]:-0} + ${tpl_counts[9]:-0} + ${tpl_counts[10]:-0} ))
            t_json_plain=$(( ${tpl_counts[11]:-0} ))
            t_binary_gzip=$(( ${tpl_counts[12]:-0} + ${tpl_counts[13]:-0} ))
            t_binary_plain=$(( ${tpl_counts[14]:-0} + ${tpl_counts[15]:-0} ))
            t_svg=$(( ${tpl_counts[16]:-0} + ${tpl_counts[17]:-0} ))
            t_other=$(( ${tpl_counts[18]:-0} + ${tpl_counts[19]:-0} ))
            tpl_json=",
  \"tpl_static_gzip\": $t_static_gzip,
  \"tpl_json_gzip\": $t_json_gzip,
  \"tpl_static_plain\": $t_static_plain,
  \"tpl_json_plain\": $t_json_plain,
  \"tpl_binary_gzip\": $t_binary_gzip,
  \"tpl_binary_plain\": $t_binary_plain,
  \"tpl_svg\": $t_svg,
  \"tpl_other\": $t_other"
        fi
        if [ -n "$tpl_line" ] && [ -n "${CUSTOM_TPL_PARSER:-}" ]; then
            tpl_json=$(echo "$best_output" | bash -c "$CUSTOM_TPL_PARSER")
        fi
    fi

    # Save results only with --save flag
    if [ "$SAVE_RESULTS" = "true" ]; then
        mkdir -p "$RESULTS_DIR/$profile/$CONNS"
        cat > "$RESULTS_DIR/$profile/${CONNS}/${FRAMEWORK}.json" <<EOF
{
  "framework": "$DISPLAY_NAME",
  "language": "$LANGUAGE",
  "rps": $best_rps,
  "avg_latency": "$avg_lat",
  "p99_latency": "$p99_lat",
  "cpu": "$best_cpu",
  "memory": "$best_mem",
  "connections": $CONNS,
  "threads": $THREADS,
  "duration": "$DURATION",
  "pipeline": $pipeline,
  "bandwidth": "$bandwidth",
  "input_bw": "$input_bw",
  "reconnects": $reconnects,
  "status_2xx": ${status_2xx:-0},
  "status_3xx": ${status_3xx:-0},
  "status_4xx": ${status_4xx:-0},
  "status_5xx": ${status_5xx:-0}${tpl_json}
}
EOF
        echo "[saved] results/$profile/${CONNS}/${FRAMEWORK}.json"

        # Save docker logs
        LOGS_DIR="$ROOT_DIR/site/static/logs/$profile/$CONNS"
        mkdir -p "$LOGS_DIR"
        docker logs "$CONTAINER_NAME" > "$LOGS_DIR/${FRAMEWORK}.log" 2>&1 || true
        # Truncate large logs (>10MB) to last 5000 lines
        if [ -f "$LOGS_DIR/${FRAMEWORK}.log" ] && [ "$(stat -c%s "$LOGS_DIR/${FRAMEWORK}.log" 2>/dev/null)" -gt 10485760 ] 2>/dev/null; then
            tail -5000 "$LOGS_DIR/${FRAMEWORK}.log" > "$LOGS_DIR/${FRAMEWORK}.log.tmp" && mv "$LOGS_DIR/${FRAMEWORK}.log.tmp" "$LOGS_DIR/${FRAMEWORK}.log"
        fi
        echo "[saved] site/static/logs/$profile/${CONNS}/${FRAMEWORK}.log"
    else
        echo "[dry-run] Results not saved (use --save to persist)"
    fi

    # Stop container before next connection count
    docker stop -t 5 "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    done # CONNS loop

done

# Rebuild site data only with --save
if [ "$SAVE_RESULTS" = "true" ]; then
    rebuild_site_data
fi
