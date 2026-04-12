#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FRAMEWORKS_DIR="$ROOT_DIR/frameworks"
BENCHMARK="$SCRIPT_DIR/benchmark.sh"
LOG_DIR="$ROOT_DIR/results/logs"
mkdir -p "$LOG_DIR"

# Frameworks to skip (already benchmarked)
SKIP_LIST=""

# Tests to skip (already completed)
SKIP_TESTS=""

# Ordered test profiles
TESTS=(baseline pipelined limited-conn json upload api-4 api-16 static async-db baseline-h2 static-h2 baseline-h3 static-h3 unary-grpc unary-grpc-tls echo-ws)

# Collect enabled frameworks and their supported tests
declare -A FW_TESTS
frameworks=()
for meta in "$FRAMEWORKS_DIR"/*/meta.json; do
    dir="$(dirname "$meta")"
    name="$(basename "$dir")"
    if [ -n "$SKIP_LIST" ] && echo "$SKIP_LIST" | grep -qw "$name"; then
        continue
    fi
    enabled=$(python3 -c "import json; print(json.load(open('$meta')).get('enabled', True))" 2>/dev/null || echo "True")
    if [ "$enabled" != "True" ]; then
        continue
    fi
    tests=$(python3 -c "import json; print(' '.join(json.load(open('$meta')).get('tests', [])))" 2>/dev/null || echo "")
    frameworks+=("$name")
    FW_TESTS[$name]="$tests"
done

total_tests=${#TESTS[@]}
total_fw=${#frameworks[@]}

echo "=== Benchmark per test: $total_tests tests × $total_fw frameworks ==="
echo ""

passed=0
failed=0
skipped=0
failed_list=()

for ti in "${!TESTS[@]}"; do
    test="${TESTS[$ti]}"
    tn=$((ti + 1))

    if [ -n "$SKIP_TESTS" ] && echo "$SKIP_TESTS" | grep -qw "$test"; then
        echo "[$tn/$total_tests] $test — SKIPPED"
        echo ""
        continue
    fi

    # Collect frameworks that support this test
    eligible=()
    for fw in "${frameworks[@]}"; do
        if echo "${FW_TESTS[$fw]}" | grep -qw "$test"; then
            eligible+=("$fw")
        fi
    done

    echo "[$tn/$total_tests] $test (${#eligible[@]} frameworks)"

    for fi_idx in "${!eligible[@]}"; do
        fw="${eligible[$fi_idx]}"
        fn=$((fi_idx + 1))
        log="$LOG_DIR/${test}_${fw}.log"

        echo "  [$fn/${#eligible[@]}] $fw"
        if "$BENCHMARK" "$fw" "$test" --save > "$log" 2>&1; then
            echo "           PASS"
            ((++passed))
        else
            echo "           FAIL (see $log)"
            ((++failed))
            failed_list+=("$test:$fw")
        fi

        # Cool-down between frameworks
        if [ "$fn" -lt "${#eligible[@]}" ]; then
            sleep 15
        fi
    done

    # Cool-down between tests
    if [ "$tn" -lt "$total_tests" ]; then
        echo "  Waiting 15s before next test..."
        sleep 15
    fi
    echo ""
done

echo "=== Done ==="
echo "Passed: $passed"
if [ "$failed" -gt 0 ]; then
    echo "Failed: $failed — ${failed_list[*]}"
    exit 1
fi
