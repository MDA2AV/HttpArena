#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FRAMEWORKS_DIR="$ROOT_DIR/frameworks"
BENCHMARK="$SCRIPT_DIR/benchmark.sh"
LOG_DIR="$ROOT_DIR/results/logs"
mkdir -p "$LOG_DIR"

# Determine test profile from script name: benchmark-<test>.sh -> <test>
SELF="$(basename "$0")"
TEST="${SELF#benchmark-}"
TEST="${TEST%.sh}"

if [ "$TEST" = "test" ]; then
    echo "Usage: call via a symlink like benchmark-baseline.sh"
    echo "  or:  $0 <test-profile>"
    echo ""
    echo "Available profiles:"
    echo "  baseline pipelined limited-conn json upload"
    echo "  api-4 api-16 static async-db"
    echo "  baseline-h2 static-h2 baseline-h3 static-h3"
    echo "  unary-grpc unary-grpc-tls echo-ws"
    exit 1
fi

# Allow override via first argument
if [ $# -ge 1 ]; then
    TEST="$1"
fi

# Collect enabled frameworks that support this test
frameworks=()
for meta in "$FRAMEWORKS_DIR"/*/meta.json; do
    dir="$(dirname "$meta")"
    name="$(basename "$dir")"
    enabled=$(python3 -c "import json; m=json.load(open('$meta')); print(m.get('enabled',True) and '$TEST' in m.get('tests',[]))" 2>/dev/null || echo "False")
    if [ "$enabled" = "True" ]; then
        frameworks+=("$name")
    fi
done

total=${#frameworks[@]}
echo "=== $TEST: $total frameworks ==="
echo ""

passed=0
failed=0
failed_list=()

for i in "${!frameworks[@]}"; do
    fw="${frameworks[$i]}"
    n=$((i + 1))
    log="$LOG_DIR/${TEST}_${fw}.log"

    echo "[$n/$total] $fw"
    if "$BENCHMARK" "$fw" "$TEST" --save > "$log" 2>&1; then
        echo "         PASS"
        ((++passed))
    else
        echo "         FAIL (see $log)"
        ((++failed))
        failed_list+=("$fw")
    fi

    if [ "$n" -lt "$total" ]; then
        echo "         Waiting 15s..."
        sleep 15
    fi
done

echo ""
echo "=== $TEST done ==="
echo "Passed: $passed / $total"
if [ "$failed" -gt 0 ]; then
    echo "Failed: $failed — ${failed_list[*]}"
    exit 1
fi
