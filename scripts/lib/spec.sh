# scripts/lib/spec.sh — the protocol-compliance suites an entry can subscribe
# to with "spec" in meta.json, and the checks on that list. Sourced by both
# validate.sh and spec.sh, so the two cannot disagree about what a suite needs.
# See site/content/docs/test-profiles/compliance/.
#
# No dependencies on the other lib files: validate.sh sources only this and
# profiles.sh.

SPEC_KNOWN="h1 h2 h3 ws"
SPEC_SUITES=""

# The profiles a suite can run against; an entry has to run at least one of
# them. h1 means a listener on :8080, h2 one on :8443 or :8082, h3 the QUIC
# listener, ws the /ws echo.
spec_profiles_for() {
    case "$1" in
        h1) echo "baseline pipelined limited-conn json-comp async async-db fortunes latency-1m latency-10k latency-500k-8cpu" ;;
        h2) echo "baseline-h2 static-h2 baseline-h2c json-h2c" ;;
        h3) echo "baseline-h3 static-h3" ;;
        ws) echo "echo-ws echo-ws-pipeline echo-ws-limited" ;;
        *)  return 1 ;;
    esac
}

# Read "spec" from a meta.json into SPEC_SUITES, space-separated. Returns 1
# when the value is there but is not a list of strings.
spec_load() {
    SPEC_SUITES=$(python3 -c "
import json, sys
v = json.load(open(sys.argv[1])).get('spec', [])
print(' '.join(v) if isinstance(v, list) and all(isinstance(s, str) for s in v) else '!')" "$1")
    [ "$SPEC_SUITES" != "!" ]
}

spec_has() {
    [[ " $SPEC_SUITES " == *" $1 "* ]]
}

# Check SPEC_SUITES against the entry's tests ($1, separated by spaces or
# commas). Prints one line per problem and returns 1 if there is any.
spec_check() {
    local tests=" ${1//,/ } " s p need ok bad=0
    for s in $SPEC_SUITES; do
        if ! need=$(spec_profiles_for "$s"); then
            echo "$s: not a compliance suite (known: $SPEC_KNOWN)"
            bad=1
            continue
        fi
        ok=false
        for p in $need; do
            if [[ "$tests" == *" $p "* ]]; then ok=true; fi
        done
        if ! $ok; then
            echo "$s: the entry runs no profile it could be run against (needs one of: $need)"
            bad=1
        fi
    done
    return $bad
}
