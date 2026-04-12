#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FRAMEWORKS_DIR="$ROOT_DIR/frameworks"
BENCHMARK="$SCRIPT_DIR/benchmark.sh"
LOG_DIR="$ROOT_DIR/results/logs"
mkdir -p "$LOG_DIR"

H1_PROFILES=(baseline pipelined limited-conn json upload api-4 api-16 static async-db)

# Frameworks to skip (already benchmarked)
SKIP_LIST=""

# Parse flags
SAVE_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --save) SAVE_FLAG="--save" ;;
        --skip=*) SKIP_LIST="${arg#--skip=}" ;;
    esac
done

# Collect enabled frameworks from meta.json
frameworks=()
for meta in "$FRAMEWORKS_DIR"/*/meta.json; do
    dir="$(dirname "$meta")"
    name="$(basename "$dir")"
    if [ -n "$SKIP_LIST" ] && echo "$SKIP_LIST" | grep -qw "$name"; then
        echo "SKIP  $name (in skip list)"
        continue
    fi
    enabled=$(python3 -c "import json; print(json.load(open('$meta')).get('enabled', True))" 2>/dev/null || echo "True")
    if [ "$enabled" = "True" ]; then
        frameworks+=("$name")
    else
        echo "SKIP  $name (disabled)"
    fi
done

total=${#frameworks[@]}
num_profiles=${#H1_PROFILES[@]}
echo "=== HTTP/1.1 Benchmark: $total frameworks × $num_profiles profiles ==="
echo "Profiles: ${H1_PROFILES[*]}"
echo ""

passed=0
failed=0
skipped=0
failed_list=()

for i in "${!frameworks[@]}"; do
    fw="${frameworks[$i]}"
    n=$((i + 1))
    meta="$FRAMEWORKS_DIR/$fw/meta.json"
    fw_tests=$(python3 -c "import json,sys; print(','.join(json.load(open(sys.argv[1])).get('tests',[])))" "$meta" 2>/dev/null || echo "")

    # Check if framework subscribes to any H1 profile
    has_h1=false
    for profile in "${H1_PROFILES[@]}"; do
        if echo ",$fw_tests," | grep -qF ",$profile,"; then
            has_h1=true
            break
        fi
    done
    if [ "$has_h1" = "false" ]; then
        echo "[$n/$total] $fw — no H/1.1 tests, skipping"
        continue
    fi

    for profile in "${H1_PROFILES[@]}"; do
        if ! echo ",$fw_tests," | grep -qF ",$profile,"; then
            ((++skipped))
            continue
        fi
        log="$LOG_DIR/${fw}-${profile}.log"
        echo "[$n/$total] $fw :: $profile"
        if "$BENCHMARK" "$fw" "$profile" $SAVE_FLAG > "$log" 2>&1; then
            echo "         PASS"
            ((++passed))
        else
            echo "         FAIL (see $log)"
            ((++failed))
            failed_list+=("$fw:$profile")
        fi
    done

    # Cool-down between frameworks
    if [ "$n" -lt "$total" ]; then
        echo "         Waiting 15s..."
        sleep 15
    fi
done

echo ""
echo "=== Done ==="
echo "Passed: $passed | Skipped: $skipped"
if [ "$failed" -gt 0 ]; then
    echo "Failed: $failed — ${failed_list[*]}"
    exit 1
fi
