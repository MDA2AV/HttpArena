#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
SITE_DATA="$ROOT_DIR/site/data"
ROUNDS_DIR="$SITE_DATA/rounds"

usage() {
    echo "Usage:"
    echo "  $0 create <name>   Archive current results as a named round"
    echo "  $0 list            List all archived rounds"
    echo "  $0 delete <id>     Delete an archived round"
    echo ""
    echo "Examples:"
    echo "  $0 create \"Round 1 — March 2026\""
    echo "  $0 list"
    echo "  $0 delete 1"
    exit 1
}

CMD="${1:-}"
[ -z "$CMD" ] && usage

case "$CMD" in
create)
    NAME="${2:-}"
    [ -z "$NAME" ] && { echo "Error: round name required"; usage; }

    mkdir -p "$ROUNDS_DIR"

    # Determine next round ID
    NEXT_ID=1
    if [ -f "$ROUNDS_DIR/index.json" ]; then
        MAX_ID=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    rounds = json.load(f)
ids = [r['id'] for r in rounds]
print(max(ids) if ids else 0)
" "$ROUNDS_DIR/index.json")
        NEXT_ID=$((MAX_ID + 1))
    fi

    DATE=$(date +%Y-%m-%d)

    # Read system info from current.json (written by benchmark.sh --save).
    # commit is intentionally NOT in current.json anymore (it churned per PR
    # and dominated merge conflicts); always derive it from git directly.
    CURRENT_JSON="$SITE_DATA/current.json"
    COMMIT=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [ -f "$CURRENT_JSON" ]; then
        CPU=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('cpu','unknown'))")
        CORES=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('cores','unknown'))")
        THREADS=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('threads','unknown'))")
        THREADS_PER_CORE=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('threads_per_core','unknown'))")
        RAM=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('ram','unknown'))")
        RAM_SPEED=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('ram_speed','unknown'))")
        GOVERNOR=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('governor','unknown'))")
        OS_INFO=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('os','unknown'))")
        KERNEL=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('kernel','unknown'))")
        DOCKER=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('docker','unknown'))")
        DOCKER_RUNTIME=$(python3 -c "import json; print(json.load(open('$CURRENT_JSON')).get('docker_runtime','unknown'))")
    else
        echo "Warning: site/data/current.json not found — run benchmark.sh --save first"
        CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
        THREADS=$(nproc 2>/dev/null || echo "unknown")
        THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
        CORES="$THREADS"
        if [ "$THREADS_PER_CORE" -gt 0 ] 2>/dev/null; then
            CORES=$((THREADS / THREADS_PER_CORE))
        fi
        RAM=$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')
        RAM_SPEED=$(sudo dmidecode -t memory 2>/dev/null | awk '/Configured Memory Speed:/ && /MHz/ {print $4 " MHz"; exit}')
        [ -z "$RAM_SPEED" ] && RAM_SPEED="unknown"
        GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
        OS_INFO=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)
        KERNEL=$(uname -r)
        DOCKER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        DOCKER_RUNTIME=$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo "unknown")
    fi

    # Bundle all result data into one JSON
    python3 -c "
import json, glob, os, sys

site_data = sys.argv[1]
round_file = sys.argv[2]

bundle = {}
for f in sorted(glob.glob(os.path.join(site_data, '*.json'))):
    name = os.path.basename(f)
    if name in ('frameworks.json', 'langcolors.json'):
        continue
    if name.startswith('rounds'):
        continue
    key = os.path.splitext(name)[0]
    with open(f) as fh:
        bundle[key] = json.load(fh)

# Include frameworks metadata
fw_path = os.path.join(site_data, 'frameworks.json')
if os.path.exists(fw_path):
    with open(fw_path) as fh:
        bundle['_frameworks'] = json.load(fh)

with open(round_file, 'w') as fh:
    json.dump(bundle, fh, separators=(',', ':'))
" "$SITE_DATA" "$ROUNDS_DIR/${NEXT_ID}.json"

    # Update index
    python3 -c "
import json, os, sys

index_path = sys.argv[1]
round_id = int(sys.argv[2])
name = sys.argv[3]
date = sys.argv[4]
cpu = sys.argv[5]
cores = sys.argv[6]
ram = sys.argv[7]
ram_speed = sys.argv[8]
os_info = sys.argv[9]
kernel = sys.argv[10]
commit = sys.argv[11]
docker = sys.argv[12]
governor = sys.argv[13]
docker_runtime = sys.argv[14]
threads_per_core = sys.argv[15]
current_json = sys.argv[16]
threads = sys.argv[17]

rounds = []
if os.path.exists(index_path):
    with open(index_path) as f:
        rounds = json.load(f)

smt = 'on' if threads_per_core == '2' else 'off' if threads_per_core == '1' else None

entry = {
    'id': round_id,
    'name': name,
    'date': date,
    'cpu': cpu,
    'cores': cores,
    'threads': threads,
    'ram': ram,
    'os': os_info,
    'kernel': kernel,
    'docker': docker,
    'docker_runtime': docker_runtime,
    'governor': governor,
    'commit': commit
}
if ram_speed != 'unknown':
    entry['ram_speed'] = ram_speed
if smt is not None:
    entry['smt'] = smt

# Copy tcp config from current.json
if os.path.exists(current_json):
    with open(current_json) as f:
        cur = json.load(f)
    if 'tcp' in cur:
        entry['tcp'] = cur['tcp']

rounds.append(entry)

with open(index_path, 'w') as f:
    json.dump(rounds, f, indent=2)
" "$ROUNDS_DIR/index.json" "$NEXT_ID" "$NAME" "$DATE" "$CPU" "$CORES" "$RAM" "$RAM_SPEED" "$OS_INFO" "$KERNEL" "$COMMIT" "$DOCKER" "$GOVERNOR" "$DOCKER_RUNTIME" "$THREADS_PER_CORE" "$CURRENT_JSON" "$THREADS"

    # Clear current results so the new ongoing round starts fresh
    rm -rf "$ROOT_DIR/results"/*
    # Rebuild site data (produces empty data files)
    for f in "$SITE_DATA"/*.json; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        [ "$fname" = "langcolors.json" ] && continue
        [ "$fname" = "frameworks.json" ] && continue
        [ "$fname" = "current.json" ] && continue
        echo '[]' > "$f"
    done
    echo '{}' > "$SITE_DATA/frameworks.json"
    rm -f "$SITE_DATA/current.json"

    echo "[archived] Round $NEXT_ID: $NAME ($DATE)"
    echo "[hardware] $CPU (${CORES}C/${THREADS}T), $RAM RAM"
    echo "[system]   $OS_INFO (kernel $KERNEL)"
    echo "[commit]   $COMMIT"
    echo "[file]     site/data/rounds/${NEXT_ID}.json"
    echo "[reset]    results/ cleared — new round started"
    ;;

list)
    if [ ! -f "$ROUNDS_DIR/index.json" ]; then
        echo "No archived rounds."
        exit 0
    fi
    python3 -c "
import json, os, sys
with open(sys.argv[1]) as f:
    rounds = json.load(f)
if not rounds:
    print('No archived rounds.')
else:
    for r in rounds:
        size = os.path.getsize(os.path.join(sys.argv[2], str(r['id']) + '.json'))
        print(f\"  #{r['id']:>2}  {r['name']:<40}  {r['date']}  ({size // 1024}KB)\")
" "$ROUNDS_DIR/index.json" "$ROUNDS_DIR"
    ;;

delete)
    ID="${2:-}"
    [ -z "$ID" ] && { echo "Error: round ID required"; usage; }
    if [ ! -f "$ROUNDS_DIR/${ID}.json" ]; then
        echo "Error: round $ID not found"
        exit 1
    fi
    rm -f "$ROUNDS_DIR/${ID}.json"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    rounds = json.load(f)
rounds = [r for r in rounds if r['id'] != int(sys.argv[2])]
with open(sys.argv[1], 'w') as f:
    json.dump(rounds, f, indent=2)
" "$ROUNDS_DIR/index.json" "$ID"
    echo "[deleted] Round $ID"
    ;;

*)
    usage
    ;;
esac
