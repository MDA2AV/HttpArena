#!/usr/bin/env bash
# scripts/resilience.sh — run the resilience attacks against an entry in a
# memory- and CPU-capped container and record whether it survives.
#
#   ./scripts/resilience.sh <framework> [--save] [attack ...]
#
# The entry runs in a fixed box (RES_MEM / RES_CPUSET, default 4g / 2 CPUs) so an
# attack that exhausts memory OOM-kills the container — a signal we can read —
# instead of taking the host down. Each attack gets a FRESH container (a crash in
# one must not cost another its verdict), reusing the normal entry launch path
# (framework_start) with the memory cap turned on.
#
# For each attack we record:
#   verdict        survived | degraded | hung | crashed | oom-killed
#   peak RSS       cgroup high-water during the attack, vs the idle baseline
#   liveness       a plaintext GET every second *during* the attack
#   recovery       seconds until the server serves again *after* the attack stops
# plus what the attack client itself did (scripts/resilience/attack.py).
#
# Scores land in results/resilience/<dir>.json (raw per-attack data next to it in
# results/resilience/<dir>/); --save also writes site/data/resilience/<dir>.json.
# <dir> is the entry directory, not the display name — same rule as spec/tls.
#
# The image is built unless RES_SKIP_BUILD=1 (a caller that just built it).
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
source "$SOURCE_DIR/common.sh"
source "$SOURCE_DIR/framework.sh"
source "$SOURCE_DIR/profiles.sh"
cd "$ROOT_DIR"

SAVE=false
POSITIONAL=()
ATTACKS_REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        --save) SAVE=true ;;
        slow-body|slow-headers|huge-chunk|decompression-bomb|hashdos|json-nesting-bomb|multipart-flood|redos-headers|continuation-flood|hpack-bomb|rapid-reset|madeyoureset|settings-flood|ping-flood|empty-frame-flood|window-stall|slow-read|large-upload|keepalive-hoard|content-length-prealloc|expect-100-continue|chunk-size-overflow|trailer-flood|chunk-extension-flood|tiny-chunk-flood|header-bomb|header-count-flood|duplicate-header-merge|pipelining-flood|decomp-codec-bypass|qvalue-cpu-bomb|cookie-flood|percent-decode-quadratic|range-bomb|json-bignum|ws-giant-frame|ws-fragment-bomb|ws-deflate-bomb|ws-pong-flood|tls-handshake-flood|dheat) ATTACKS_REQUESTED+=("$arg") ;;
        -*)     fail "unknown flag: $arg" ;;
        *)      POSITIONAL+=("$arg") ;;
    esac
done
[ -n "${POSITIONAL[0]:-}" ] || fail "usage: resilience.sh <framework> [--save] [attack ...]"

# ── Knobs (all env-overridable) ──────────────────────────────────────────────
RES_MEM="${RES_MEM:-4g}"             # the box the entry runs in
# One physical core + its SMT sibling — a tight "2 hardware threads on 1 core" box,
# read from the CPU topology. A blind "0-1" is wrong on CPUs whose thread siblings
# aren't adjacent (e.g. 0,16): it would hand the server two SEPARATE physical cores,
# twice the compute we intend. Override RES_CPUSET to pin a specific set.
RES_CPUSET="${RES_CPUSET:-$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list 2>/dev/null || echo 0-1)}"
RES_DURATION="${RES_DURATION:-15}"   # max seconds per attack (verdicts are clear well inside this; an attack ends early if the server dies OR is clearly surviving)
RES_MIN_DURATION="${RES_MIN_DURATION:-8}"  # never early-exit "clearly surviving" before this many seconds
RES_SETTLE="${RES_SETTLE:-6}"        # ... and only once peak RSS has been flat (and liveness 100%) this long
RES_CONNS="${RES_CONNS:-4000}"       # connections the slow attacks hold (< the 28k ephemeral-port ceiling)
RES_BODY_SIZE="${RES_BODY_SIZE:-104857600}"  # 100 MiB declared body for slow-body (pre-alloc pressure)
RES_DRIP="${RES_DRIP:-1.0}"          # seconds between drips
RES_DRIP_BYTES="${RES_DRIP_BYTES:-256}"       # bytes per drip for slow-body/huge-chunk: ~256 B/s, slow
                                              # enough to be low-and-slow but above a bytes-at-zero reaper
RES_H2_CONNS="${RES_H2_CONNS:-256}"           # connections for the HTTP/2 flood attacks (each floods hard)
RES_DECOMP_CONNS="${RES_DECOMP_CONNS:-64}"    # connections for the H1 payload/parser floods
RES_BOMB_SIZE="${RES_BOMB_SIZE:-1073741824}"  # 1 GiB decompressed per gzip bomb
RES_HASHDOS_KEYS="${RES_HASHDOS_KEYS:-100000}"      # form keys for hashdos
RES_JSON_DEPTH="${RES_JSON_DEPTH:-100000}"          # array nesting depth for json-nesting-bomb
RES_MULTIPART_PARTS="${RES_MULTIPART_PARTS:-50000}" # parts for multipart-flood
RES_REDOS_PAD="${RES_REDOS_PAD:-4000}"              # ambiguous-run length for redos-headers
RES_STALL_COUNT="${RES_STALL_COUNT:-5000}"          # /json/{count} size per stalled stream (window-stall)
RES_STALL_STREAMS="${RES_STALL_STREAMS:-64}"        # stalled streams per connection (window-stall)
RES_WS_CONNS="${RES_WS_CONNS:-256}"                 # connections for the WebSocket attacks
RES_TLS_CONNS="${RES_TLS_CONNS:-128}"               # workers for the TLS handshake attacks
RES_CL_DECLARE="${RES_CL_DECLARE:-2147483648}"      # declared Content-Length (content-length-prealloc/expect-100)
RES_CHUNK_EXT_SIZE="${RES_CHUNK_EXT_SIZE:-4096}"    # chunk-extension bytes per chunk (chunk-extension-flood)
RES_CHUNK_COUNT="${RES_CHUNK_COUNT:-500000}"        # 1-byte chunks (tiny-chunk-flood)
RES_HEADER_VALUE_SIZE="${RES_HEADER_VALUE_SIZE:-1048576}"  # one header value's size (header-bomb)
RES_HEADER_COUNT="${RES_HEADER_COUNT:-50000}"       # header fields (header-count-flood)
RES_DUP_HEADERS="${RES_DUP_HEADERS:-20000}"         # repeats of one header name (duplicate-header-merge)
RES_PIPELINE_DEPTH="${RES_PIPELINE_DEPTH:-10000}"   # pipelined requests per batch (pipelining-flood)
RES_UPLOAD_SIZE="${RES_UPLOAD_SIZE:-2147483648}"    # bytes actually delivered (large-upload)
# Header-based attacks are bounded by the server's per-header / total-header size
# cap (itself a first-line defense): too big and the request is rejected for size
# before the quadratic sort / cookie-count path is reached. These defaults keep the
# header ~7 KiB, under a common 8 KiB cap, so the attack actually exercises the path.
RES_QVALUE_COUNT="${RES_QVALUE_COUNT:-600}"         # Accept-Language entries (qvalue-cpu-bomb)
RES_COOKIE_PAIRS="${RES_COOKIE_PAIRS:-1000}"        # cookie pairs (cookie-flood)
RES_PERCENT_COUNT="${RES_PERCENT_COUNT:-2000}"      # %-encoded tokens in the path (percent-decode-quadratic)
RES_RANGE_COUNT="${RES_RANGE_COUNT:-1000}"          # byte ranges (range-bomb)
RES_BIGNUM_DIGITS="${RES_BIGNUM_DIGITS:-100000}"    # digits in the JSON number (json-bignum)
RES_WS_FRAME_LEN="${RES_WS_FRAME_LEN:-9223372036854775552}"  # declared WS frame length (ws-giant-frame)
RES_WS_FRAG_SIZE="${RES_WS_FRAG_SIZE:-4096}"        # bytes per WS fragment (ws-fragment-bomb)
RES_RECOVERY="${RES_RECOVERY:-15}"   # seconds to wait for the server to serve again
# The attack client gets EVERY logical CPU except the server's core+sibling, so it
# never shares a physical core with the (deliberately CPU-starved) server and has
# maximum firepower. Derived from RES_CPUSET — GCANNON_CPUS (half the box) could
# overlap the server's SMT sibling on a non-adjacent-sibling CPU.
ATTACK_CPUS="${ATTACK_CPUS:-$(python3 -c '
import os, sys
srv = set()
for p in sys.argv[1].replace(" ", "").split(","):
    if "-" in p:
        a, b = p.split("-"); srv.update(range(int(a), int(b) + 1))
    elif p:
        srv.add(int(p))
rest = [c for c in range(os.cpu_count() or 2) if c not in srv]
print(",".join(map(str, rest)) or "0")
' "$RES_CPUSET" 2>/dev/null || echo "$GCANNON_CPUS")}"
ATTACK_PY="$SCRIPT_DIR/resilience/attack.py"
ATTACK_GO_DIR="$SCRIPT_DIR/resilience/attacker"
ATTACK_GO_BIN="$ATTACK_GO_DIR/attacker"
# The GIL-bound floods go to the Go client: CPython's GIL caps frame-construction
# floods (rapid-reset et al.) near one core of real work no matter how many cores
# taskset grants, so the ~60-core attack box can't actually outrun the server.
# The Go client has no GIL. Everything else (slow holds, amplification, parser,
# WebSocket, dheat) stays on attack.py, where the GIL is not the bottleneck.
# RES_USE_GO=0 forces the Python client everywhere.
RES_GO_ATTACKS=" continuation-flood hpack-bomb rapid-reset madeyoureset settings-flood ping-flood empty-frame-flood large-upload pipelining-flood tls-handshake-flood "
RES_USE_GO="${RES_USE_GO:-1}"

# Build the Go attack client once per run: native `go build` if the host has go,
# else build the fallback image and extract the static binary. Any failure drops
# back to the Python client (RES_USE_GO=0) rather than aborting the run.
build_go_attacker() {
    [ "$RES_USE_GO" = "1" ] || return 0
    if [ -x "$ATTACK_GO_BIN" ] && [ "$ATTACK_GO_BIN" -nt "$ATTACK_GO_DIR/main.go" ]; then
        info "Go attack client is up to date"; return 0
    fi
    if command -v go >/dev/null 2>&1; then
        info "building the Go attack client (go build)"
        if ( cd "$ATTACK_GO_DIR" && CGO_ENABLED=0 go build -trimpath -o attacker . ); then
            return 0
        fi
        warn "go build failed — using the Python attack client"; RES_USE_GO=0; return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        info "no native go — building the Go attack client in docker"
        # Empty DOCKER_CONFIG so the base-image pull skips a broken credential
        # helper (docker-desktop leaves one that isn't on PATH). create/cp need
        # no config once the image is local.
        local _dctmp; _dctmp=$(mktemp -d); printf '{}' > "$_dctmp/config.json"
        if DOCKER_CONFIG="$_dctmp" docker build -q -t httparena-resilience-attacker:local \
                -f "$ROOT_DIR/docker/resilience-attacker.Dockerfile" "$ATTACK_GO_DIR" >/dev/null 2>&1; then
            local cid; cid=$(docker create httparena-resilience-attacker:local 2>/dev/null) || cid=""
            if [ -n "$cid" ] && docker cp "$cid:/attacker" "$ATTACK_GO_BIN" >/dev/null 2>&1; then
                docker rm -f "$cid" >/dev/null 2>&1 || true
                chmod +x "$ATTACK_GO_BIN"; rm -rf "$_dctmp"; return 0
            fi
            [ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1 || true
        fi
        rm -rf "$_dctmp"
        warn "docker build/extract of the Go client failed — using the Python client"; RES_USE_GO=0; return 0
    fi
    warn "neither go nor docker available — using the Python attack client"; RES_USE_GO=0
}

# ── Entry ────────────────────────────────────────────────────────────────────
framework_load_meta "${POSITIONAL[0]}"
CONTAINER_NAME="httparena-resilience-${FRAMEWORK}"
trap 'framework_stop' EXIT

# Per-entry opt-in. An entry runs in the benchmark only when it sets
# "resilience": true in meta.json — the attacks are destructive and need the
# whole machine, so this is off by default. An explicit attack list on the CLI
# overrides the gate, for local debugging of an entry that has not opted in yet.
RES_OPT_IN=$(python3 -c "
import json, sys
print('1' if json.load(open(sys.argv[1])).get('resilience') else '0')" \
    "$ROOT_DIR/frameworks/$FRAMEWORK/meta.json" 2>/dev/null || echo 0)
if [ "${#ATTACKS_REQUESTED[@]}" -eq 0 ] && [ "$RES_OPT_IN" != "1" ]; then
    info "$FRAMEWORK has not opted into the resilience suite (set \"resilience\": true in meta.json, or name attacks on the CLI to force a run) — nothing to do"
    # An entry that opted back out takes its saved verdicts with it (mirror spec.sh).
    if $SAVE && [ -f "$ROOT_DIR/site/data/resilience/$FRAMEWORK.json" ]; then
        rm -f "$ROOT_DIR/site/data/resilience/$FRAMEWORK.json"
        info "removed site/data/resilience/$FRAMEWORK.json"
    fi
    exit 0
fi

if [ "${RES_SKIP_BUILD:-0}" = "1" ] && docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    info "RES_SKIP_BUILD=1 — reusing $IMAGE_NAME"
else
    framework_build
fi

WORK="$RESULTS_DIR/resilience/$FRAMEWORK"
rm -rf "$WORK"
mkdir -p "$WORK"

# ── Which attacks apply ──────────────────────────────────────────────────────
# The H1 attacks run against any entry. continuation-flood needs an HTTP/2
# listener, so it runs only when the entry subscribes to an h2/h2c profile.
# The H2 attacks all target the h2c (cleartext) listener on :8082, so gate them on
# an h2c profile ONLY. An entry that does h2 only over TLS binds :8443, not :8082 —
# gating it in here would fire the attacks at an unbound port and score 8 false
# "survived". (TLS-H2 coverage would need the attacks routed to :8443 with ALPN.)
has_h2() {
    framework_subscribes_to baseline-h2c || framework_subscribes_to json-h2c
}
has_ws() {
    framework_subscribes_to echo-ws || framework_subscribes_to echo-ws-pipeline \
 || framework_subscribes_to echo-ws-limited
}
has_h1tls() {
    framework_subscribes_to json-tls || framework_subscribes_to static-tls || framework_subscribes_to 8gbit
}
# A real TLS listener means :8081 (h1-tls profiles) or :8443 (h2-over-TLS). An
# h2c-only entry has NO TLS listener, so it must NOT be gated into the TLS attacks
# (res_tls_port would otherwise aim at an unbound :8443 and score a false pass).
has_tls() { has_h1tls || framework_subscribes_to baseline-h2 || framework_subscribes_to static-h2; }
# The TLS attacks need a TLS listener: the h1 one on 8081, else the h2 one on 8443.
res_tls_port() { if has_h1tls; then echo "$H1TLS_PORT"; else echo "$H2PORT"; fi; }
if [ "${#ATTACKS_REQUESTED[@]}" -gt 0 ]; then
    ATTACKS=("${ATTACKS_REQUESTED[@]}")
else
    ATTACKS=(slow-body slow-headers slow-read huge-chunk tiny-chunk-flood chunk-extension-flood chunk-size-overflow
             content-length-prealloc large-upload expect-100-continue keepalive-hoard
             header-bomb header-count-flood duplicate-header-merge pipelining-flood trailer-flood
             decompression-bomb decomp-codec-bypass hashdos json-nesting-bomb multipart-flood
             redos-headers qvalue-cpu-bomb cookie-flood percent-decode-quadratic range-bomb json-bignum)
    has_h2 && ATTACKS+=(continuation-flood hpack-bomb rapid-reset madeyoureset settings-flood ping-flood empty-frame-flood window-stall)
    has_ws && ATTACKS+=(ws-giant-frame ws-fragment-bomb ws-deflate-bomb ws-pong-flood)
    has_tls && ATTACKS+=(tls-handshake-flood dheat)
fi
info "attacks: ${ATTACKS[*]}"
build_go_attacker
info "box: mem=$RES_MEM cpuset=$RES_CPUSET  duration=${RES_DURATION}s conns=$RES_CONNS"

# ── Measurement helpers ──────────────────────────────────────────────────────

# Locate one of a container's cgroup files across cgroup drivers/versions.
_cgfile() {
    local id="$1" base="$2" f
    for f in "/sys/fs/cgroup/system.slice/docker-$id.scope/$base" \
             "/sys/fs/cgroup/docker/$id/$base" \
             "/sys/fs/cgroup/memory/docker/$id/$base"; do
        [ -r "$f" ] && { echo "$f"; return 0; }
    done
    f=$(find /sys/fs/cgroup -name "$base" -path "*$id*" 2>/dev/null | head -1)
    [ -n "$f" ] && [ -r "$f" ] && { echo "$f"; return 0; }
    return 1
}

# Current RSS in bytes (cgroup v2 memory.current, v1 memory.usage_in_bytes).
read_mem() {
    local id="$1" f
    f=$(_cgfile "$id" memory.current) || f=$(_cgfile "$id" memory.usage_in_bytes) || { echo 0; return; }
    cat "$f" 2>/dev/null || echo 0
}

# Kernel-maintained high-water RSS in bytes (cgroup v2 memory.peak, v1
# memory.max_usage_in_bytes). Reset per container, and we use a fresh container
# per attack, so this is the peak during this attack.
read_peak() {
    local id="$1" f
    f=$(_cgfile "$id" memory.peak) || f=$(_cgfile "$id" memory.max_usage_in_bytes) || { echo 0; return; }
    cat "$f" 2>/dev/null || echo 0
}

# Fallback sampler: on kernels without memory.peak, poll memory.current and keep
# the max in $1. Runs in the background during the attack.
sample_mem() {
    local id="$1" out="$2" f max=0 v
    f=$(_cgfile "$id" memory.current) || f=$(_cgfile "$id" memory.usage_in_bytes) || { echo 0 > "$out"; return; }
    echo 0 > "$out"
    while :; do
        v=$(cat "$f" 2>/dev/null || echo 0)
        [ "$v" -gt "$max" ] 2>/dev/null && { max=$v; echo "$max" > "$out"; }
        sleep 0.2
    done
}

# Seconds until a plaintext GET succeeds again, or "dead" after the budget.
recovery_probe() {
    local max="$1" start now i
    start=$(date +%s.%N)
    for ((i = 0; i < max * 2; i++)); do
        if curl -sk -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
            now=$(date +%s.%N)
            awk "BEGIN{printf \"%.1f\", $now - $start}"
            return
        fi
        sleep 0.5
    done
    echo dead
}

# ── One attack ───────────────────────────────────────────────────────────────

run_attack() {
    local name="$1" port path conns needtls=0
    case "$name" in
        # H1 slow / hold / drip — hold many connections (RES_CONNS)
        slow-body|huge-chunk) port=$PORT; path=/echo; conns=$RES_CONNS ;;
        slow-headers|slow-read|keepalive-hoard) port=$PORT; path=/; conns=$RES_CONNS ;;
        content-length-prealloc|expect-100-continue|chunk-size-overflow|trailer-flood|chunk-extension-flood) \
                            port=$PORT; path=/echo; conns=$RES_CONNS ;;
        # H1 request / payload floods on a body endpoint (RES_DECOMP_CONNS)
        # The parser-differential attacks need a body-PARSING endpoint (/parse);
        # if the entry doesn't implement it the attack reports "no-endpoint".
        decompression-bomb|decomp-codec-bypass|hashdos|json-nesting-bomb|multipart-flood|json-bignum) \
                            port=$PORT; path=/parse; conns=$RES_DECOMP_CONNS ;;
        # These just need a body sink, not a parser — /echo is fine.
        tiny-chunk-flood|large-upload) \
                            port=$PORT; path=/echo; conns=$RES_DECOMP_CONNS ;;
        # H1 header / request floods on a GET endpoint
        redos-headers|header-bomb|header-count-flood|duplicate-header-merge|pipelining-flood|qvalue-cpu-bomb|cookie-flood) \
                            port=$PORT; path=/baseline11; conns=$RES_DECOMP_CONNS ;;
        # H1 attacks that craft their own path/target
        percent-decode-quadratic|range-bomb) port=$PORT; path=/; conns=$RES_DECOMP_CONNS ;;
        # HTTP/2 floods (h2c, RES_H2_CONNS)
        continuation-flood|hpack-bomb|rapid-reset|madeyoureset|settings-flood|ping-flood|empty-frame-flood|window-stall) \
                            port=$H2C_PORT; path=/; conns=$RES_H2_CONNS ;;
        # WebSocket (/ws on 8080, RES_WS_CONNS)
        ws-giant-frame|ws-fragment-bomb|ws-deflate-bomb|ws-pong-flood) \
                            port=$PORT; path=/; conns=$RES_WS_CONNS ;;
        # TLS handshake attacks (the TLS listener, RES_TLS_CONNS)
        tls-handshake-flood|dheat) port=$(res_tls_port); path=/; conns=$RES_TLS_CONNS; needtls=1 ;;
        *) warn "unknown attack: $name"; return 0 ;;
    esac
    local tls_flag=(); [ "$needtls" = 1 ] && tls_flag=(--tls)
    log "resilience $name: $FRAMEWORK (port $port)"

    FRAMEWORK_MEM_LIMIT="$RES_MEM" framework_start resilience "$RES_CPUSET"
    if ! framework_wait_ready baseline; then
        echo '{"verdict":"error","error":"server did not come up"}' > "$WORK/$name.result.json"
        dump_container_logs "$CONTAINER_NAME" "$FRAMEWORK" 2>/dev/null || true
        framework_stop
        return 0
    fi

    local cid baseline_mem peak_file live_file sampler_pid=""
    cid=$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    baseline_mem=$(read_mem "$cid")
    peak_file="$WORK/$name.peak"
    live_file="$WORK/$name.liveness"
    : > "$live_file"

    # Liveness: a cheap GET every second during the attack.
    (
        while :; do
            if curl -sk -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/baseline11?a=1&b=1" 2>/dev/null; then
                echo ok; else echo fail; fi
            sleep 1
        done
    ) >> "$live_file" 2>/dev/null &
    local live_pid=$!

    # memory.peak gives the true high-water for free; the sampler is the fallback
    # for kernels that lack it, and we take the max of the two.
    sample_mem "$cid" "$peak_file" &
    sampler_pid=$!

    # The attack itself. tls_flag is set in the case above (TLS handshake attacks).
    # GIL-bound floods run on the Go client; everything else on attack.py. Both
    # take the identical flag set — the Go client declares and ignores the flags
    # it doesn't use — so only the binary changes. NOTE: a new --flag added to the
    # invocation below must also be declared in attacker/main.go (used or ignored),
    # or the Go-dispatched attacks exit non-zero (Go errors on an unknown flag).
    local -a client_cmd=(python3 "$ATTACK_PY")
    if [ "$RES_USE_GO" = "1" ] && [ -x "$ATTACK_GO_BIN" ] && [[ "$RES_GO_ATTACKS" == *" $name "* ]]; then
        client_cmd=("$ATTACK_GO_BIN")
        info "$name: Go attack client (no GIL)"
    fi
    taskset -c "$ATTACK_CPUS" "${client_cmd[@]}" \
        --attack "$name" --host 127.0.0.1 --port "$port" --path "$path" \
        --conns "$conns" --duration "$RES_DURATION" \
        --body-size "$RES_BODY_SIZE" --drip-interval "$RES_DRIP" \
        --drip-bytes "$RES_DRIP_BYTES" --bomb-size "$RES_BOMB_SIZE" \
        --hashdos-keys "$RES_HASHDOS_KEYS" --json-depth "$RES_JSON_DEPTH" \
        --multipart-parts "$RES_MULTIPART_PARTS" --redos-pad "$RES_REDOS_PAD" \
        --stall-count "$RES_STALL_COUNT" --stall-streams "$RES_STALL_STREAMS" \
        --cl-declare "$RES_CL_DECLARE" --chunk-ext-size "$RES_CHUNK_EXT_SIZE" \
        --chunk-count "$RES_CHUNK_COUNT" --header-value-size "$RES_HEADER_VALUE_SIZE" \
        --header-count "$RES_HEADER_COUNT" --dup-headers "$RES_DUP_HEADERS" \
        --pipeline-depth "$RES_PIPELINE_DEPTH" --upload-size "$RES_UPLOAD_SIZE" \
        --qvalue-count "$RES_QVALUE_COUNT" --cookie-pairs "$RES_COOKIE_PAIRS" \
        --percent-count "$RES_PERCENT_COUNT" --range-count "$RES_RANGE_COUNT" \
        --bignum-digits "$RES_BIGNUM_DIGITS" --ws-frame-len "$RES_WS_FRAME_LEN" \
        --ws-frag-size "$RES_WS_FRAG_SIZE" "${tls_flag[@]}" \
        > "$WORK/$name.client.json" 2> "$WORK/$name.client.log" &
    local attack_pid=$! killed_early=0
    # Early-exit on either settled outcome, so a run never burns the full duration
    # once the verdict is decided. Poll every 2s while the client runs:
    #   1. the server DIED (OOM / crash) — nothing left to measure; or
    #   2. the server is CLEARLY SURVIVING — past RES_MIN_DURATION, liveness has
    #      been 100% and peak RSS has not grown for RES_SETTLE seconds, so the
    #      attack isn't biting. A real memory leak keeps raising the peak (blocks
    #      this); a CPU/liveness hit leaves a "fail" in the probe log (blocks this).
    #      peak RSS is monotonic, so any genuine growth resets the flat timer —
    #      the failure mode is "runs longer than needed", never "stops too soon".
    local aw_start aw_now aw_elapsed aw_peak aw_last_peak=-1 aw_last_grow
    aw_start=$(date +%s); aw_last_grow=$aw_start
    while kill -0 "$attack_pid" 2>/dev/null; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)" != "true" ]; then
            info "$name: server stopped running — ending the attack early"
            kill "$attack_pid" 2>/dev/null || true
            killed_early=1
            break
        fi
        aw_now=$(date +%s); aw_elapsed=$((aw_now - aw_start))
        aw_peak=$(cat "$peak_file" 2>/dev/null || echo 0)
        [ "${aw_peak:-0}" -gt "${aw_last_peak:-0}" ] 2>/dev/null && { aw_last_peak=$aw_peak; aw_last_grow=$aw_now; }
        if [ "$aw_elapsed" -ge "$RES_MIN_DURATION" ] && [ $((aw_now - aw_last_grow)) -ge "$RES_SETTLE" ] \
           && ! grep -q fail "$live_file" 2>/dev/null; then
            info "$name: liveness 100% and peak RSS flat ${RES_SETTLE}s — ending early (clearly surviving)"
            kill "$attack_pid" 2>/dev/null || true
            killed_early=1
            break
        fi
        sleep 2
    done
    local arc=0
    wait "$attack_pid" 2>/dev/null || arc=$?
    [ "$killed_early" = 0 ] && [ "$arc" -ne 0 ] && \
        warn "attack client exited non-zero (see $name.client.log)"

    kill "$live_pid" 2>/dev/null || true; wait "$live_pid" 2>/dev/null || true
    kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true

    # Server-side verdict inputs, captured before we tear the container down.
    local oom exitc running peak sampled
    oom=$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)
    exitc=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)
    peak=$(read_peak "$cid"); sampled=$(cat "$peak_file" 2>/dev/null || echo 0)
    [ "${sampled:-0}" -gt "${peak:-0}" ] 2>/dev/null && peak=$sampled

    local recovery="dead"
    if [ "$running" = "true" ]; then
        recovery=$(recovery_probe "$RES_RECOVERY")
    fi

    framework_stop

    # Hand the raw signal to the scorer as a JSON line; it classifies the verdict.
    # Note: `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` inside
    # the $() would capture "0\n0" and break the int() below — exactly on the
    # all-failed (hung/crashed) case. Keep the fallback outside the substitution.
    local live_ok live_total
    live_ok=$(grep -c '^ok$' "$live_file" 2>/dev/null) || live_ok=0
    live_total=$(grep -c .   "$live_file" 2>/dev/null) || live_total=0
    python3 - "$WORK/$name.result.json" <<PY || warn "could not write the $name result record"
import json, sys
client = {}
try:
    client = json.load(open("$WORK/$name.client.json"))
except Exception:
    pass
json.dump({
    "attack": "$name", "port": $port,
    "oom_killed": "$oom" == "true",
    "exit_code": int("$exitc") if "$exitc".lstrip("-").isdigit() else None,
    "running": "$running" == "true",
    "baseline_mem": int("$baseline_mem" or 0),
    "peak_mem": int("$peak" or 0),
    "mem_limit": "$RES_MEM",
    "cpuset": "$RES_CPUSET",
    "duration_s": $RES_DURATION,
    "recovery": "$recovery",
    "liveness_ok": int("$live_ok" or 0),
    "liveness_total": int("$live_total" or 0),
    "client": client,
}, open(sys.argv[1], "w"))
PY
}

for attack in "${ATTACKS[@]}"; do
    # Guard so a single container-start failure (a name clash, a flaky-build abort)
    # can't trip set -e and abandon every remaining attack's verdict.
    run_attack "$attack" || warn "run_attack $attack failed — continuing"
done

# ── Scores ───────────────────────────────────────────────────────────────────
OUT="$RESULTS_DIR/resilience/$FRAMEWORK.json"
python3 "$SCRIPT_DIR/resilience_results.py" "$WORK" "$DISPLAY_NAME" "$FRAMEWORK" "${ATTACKS[@]}" > "$OUT"
info "wrote results/resilience/$FRAMEWORK.json"
if $SAVE; then
    mkdir -p "$ROOT_DIR/site/data/resilience"
    cp "$OUT" "$ROOT_DIR/site/data/resilience/$FRAMEWORK.json"
    info "saved site/data/resilience/$FRAMEWORK.json"
fi
