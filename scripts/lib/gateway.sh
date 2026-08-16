# scripts/lib/gateway.sh — multi-container compose stack lifecycle.
#
# Profiles that use a compose-orchestrated stack (instead of the single
# framework container used by isolated profiles) route through this module:
#
#   gateway-64       — h2/TLS at the edge. 2 containers: proxy + server.
#                      Compose file: compose.gateway.yml (legacy name).
#   gateway-h3       — h3/QUIC at the edge. 2 containers: proxy + server.
#                      Compose file: compose.gateway-h3.yml
#   production-stack — h2/TLS at the edge + auth sidecar + cache. 4
#                      containers: edge + authsvc + cache + server.
#                      Compose file: compose.production-stack.yml
#
# All gateway_* functions take the profile name as their second argument
# so we resolve the right compose file + expected container count per
# profile. The module name is "gateway" for historical reasons — it now
# covers all multi-container stacks.

GATEWAY_PROJECT=""
GATEWAY_ACTIVE_PROFILE=""
GATEWAY_ACTIVE_FRAMEWORK=""
GATEWAY_CONTAINERS=""
GATEWAY_CONTAINER_COUNT=0
GATEWAY_STOPPED_REDIS=false

_gateway_env() {
    # All compose invocations need the same env vars for interpolation.
    CERTS_DIR="$CERTS_DIR" \
    DATA_DIR="$DATA_DIR" \
    DATABASE_URL="$DATABASE_URL" \
    "$@"
}

# Resolve <framework>/<profile> → absolute compose file path. gateway-64
# keeps its legacy `compose.gateway.yml` name; everything else uses
# `compose.<profile>.yml`.
_gateway_compose_file() {
    local framework="$1"
    local profile="$2"
    case "$profile" in
        gateway-64) echo "$ROOT_DIR/frameworks/$framework/compose.gateway.yml" ;;
        *)          echo "$ROOT_DIR/frameworks/$framework/compose.$profile.yml" ;;
    esac
}

# Expected container count per profile. The gateway-* profiles are fixed
# at exactly 2 (proxy + server). production-stack is fixed at 4 (edge +
# authsvc + cache + server). Any other count triggers a non-fatal warning
# at startup because stats aggregation assumes the whole stack is under
# our control — leftover sidecars would skew the numbers.
_gateway_expected_containers() {
    case "$1" in
        production-stack) echo 4 ;;
        *)                echo 2 ;;
    esac
}

# Remove containers belonging to any *other* httparena compose stack.
#
# Every gateway and production stack runs network_mode: host on the same fixed
# ports - edge 8443, authsvc 9090, server 8080 - so two of them cannot coexist.
# The `down` in gateway_up only clears this framework's own project, which means
# a stack left behind by another entry, or by a run killed between profiles,
# outlives it. Whichever service loses the race then dies on bind and takes the
# whole stack with it: in #1182 that was authsvc exiting 101 with
# "bind 0.0.0.0:9090: Address in use", reported only as "exited (101)".
#
# Matches on the compose project label, so the harness's own `docker run`
# sidecars (httparena-postgres, httparena-redis) carry no such label and are
# left alone. Running containers only - a stopped one holds no port.
# `|` rather than a space: an unlabelled container prints an empty field, and
# with whitespace splitting its name would shift into the label's position and
# match the httparena- test by accident.
_gateway_clear_stale() {
    local keep="$1" listing stale
    listing=$(docker ps --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.Names}}' 2>/dev/null)
    stale=$(printf '%s\n' "$listing" \
            | awk -F'|' -v keep="$keep" '$2 ~ /^httparena-/ && $2 != keep { print $1 }')
    [ -n "$stale" ] || return 0
    warn "another httparena compose stack is still up; removing it so this one can bind its ports"
    printf '%s\n' "$listing" \
        | awk -F'|' -v keep="$keep" '$2 ~ /^httparena-/ && $2 != keep { print "  stale: " $3 }'
    # shellcheck disable=SC2086
    docker rm -f -v $stale >/dev/null 2>&1 || true
}

# Print what each container of the failed stack said. compose reports the exit
# code and nothing else, so the reason - a bind conflict, a missing env var, a
# crash loop - was never in the run log. Reuses dump_container_logs so the
# output matches what a single-container failure already produces.
_gateway_dump_logs() {
    local project="$1" line id name
    while read -r id name; do
        [ -n "$id" ] || continue
        dump_container_logs "$id" "$name"
    done < <(docker ps -a --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.Names}}' 2>/dev/null \
             | awk -F'|' -v p="$project" '$2 == p { print $1 " " $3 }')
}

# The harness Redis sidecar and a stack's own `cache` both want the host's
# 6379, and redis_start runs once for the whole run whenever the entry
# subscribes to crud — so for any entry subscribed to both crud and
# production-stack the two collide on every run. It was invisible because the
# server depended on `cache` with the short form, which only waits for the
# container to start: the cache died, the server carried on against the
# harness Redis, and the profile published numbers measured against a cache it
# never configured. The compose files now wait for a healthy cache, which turns
# that into a failure; this gives the port up so it can succeed instead.
_gateway_yield_redis() {
    local compose_file="$1" project="$2"
    GATEWAY_STOPPED_REDIS=false
    command -v redis_stop >/dev/null 2>&1 || return 0
    [ -n "${REDIS_CONTAINER:-}" ] || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$REDIS_CONTAINER" || return 0
    _gateway_env docker compose -f "$compose_file" -p "$project" config --services 2>/dev/null \
        | grep -qx "cache" || return 0
    info "stopping the harness redis sidecar: this stack ships its own cache on the same port"
    redis_stop
    GATEWAY_STOPPED_REDIS=true
}

gateway_up() {
    local framework="$1"
    local profile="${2:-gateway-64}"
    local compose_file
    compose_file=$(_gateway_compose_file "$framework" "$profile")
    GATEWAY_PROJECT="httparena-$framework-$profile"
    GATEWAY_ACTIVE_PROFILE="$profile"
    GATEWAY_ACTIVE_FRAMEWORK="$framework"

    [ -f "$compose_file" ] || fail "$profile: compose file not found at $compose_file"

    _gateway_env docker compose -f "$compose_file" -p "$GATEWAY_PROJECT" \
        down --remove-orphans 2>/dev/null || true
    _gateway_clear_stale "$GATEWAY_PROJECT"
    _gateway_yield_redis "$compose_file" "$GATEWAY_PROJECT"

    info "starting gateway compose stack: $framework ($profile)"
    # --build forces compose to rebuild from source if any file in the
    # build context changed. Without this, an edit to a service Dockerfile
    # or Program.cs silently falls back to a stale image from the last run.
    if ! _gateway_env docker compose -f "$compose_file" -p "$GATEWAY_PROJECT" up --build -d; then
        _gateway_dump_logs "$GATEWAY_PROJECT"
        fail "gateway compose up failed"
    fi

    # Discover running container IDs for stats collection.
    sleep 2
    GATEWAY_CONTAINERS=$(docker ps -q --filter "label=com.docker.compose.project=$GATEWAY_PROJECT" 2>/dev/null | tr '\n' ' ')
    GATEWAY_CONTAINER_COUNT=$(echo "$GATEWAY_CONTAINERS" | wc -w)
    info "gateway containers: $GATEWAY_CONTAINER_COUNT ($GATEWAY_CONTAINERS)"

    local expected
    expected=$(_gateway_expected_containers "$profile")
    if [ "$GATEWAY_CONTAINER_COUNT" -ne "$expected" ]; then
        warn "$profile expects exactly $expected containers, found $GATEWAY_CONTAINER_COUNT — stats may not sum correctly"
    fi
}

gateway_down() {
    # Tear down whatever gateway stack is currently active. Callers can
    # pass (framework, profile) explicitly, but the normal cleanup path
    # (EXIT trap, post-run teardown) relies on the state gateway_up stored.
    # Before the early returns: if this stack took the harness Redis's port,
    # give it back even when there is no active stack left to tear down. The
    # subshell keeps redis_start's `fail` from exiting the caller, since this
    # also runs from the cleanup trap.
    if [ "$GATEWAY_STOPPED_REDIS" = true ]; then
        GATEWAY_STOPPED_REDIS=false
        info "restarting the harness redis sidecar"
        ( redis_start ) || warn "redis sidecar did not come back up"
    fi

    local framework="${1:-$GATEWAY_ACTIVE_FRAMEWORK}"
    local profile="${2:-$GATEWAY_ACTIVE_PROFILE}"
    [ -n "$framework" ] || return 0
    [ -n "$profile" ]   || return 0
    local compose_file
    compose_file=$(_gateway_compose_file "$framework" "$profile")
    [ -f "$compose_file" ] || return 0
    _gateway_env docker compose -f "$compose_file" -p "httparena-$framework-$profile" \
        down --remove-orphans 2>/dev/null || true
    GATEWAY_PROJECT=""
    GATEWAY_ACTIVE_PROFILE=""
    GATEWAY_ACTIVE_FRAMEWORK=""
    GATEWAY_CONTAINERS=""
    GATEWAY_CONTAINER_COUNT=0
}

gateway_service_names() {
    local framework="$1"
    local profile="${2:-gateway-64}"
    local compose_file
    compose_file=$(_gateway_compose_file "$framework" "$profile")
    _gateway_env docker compose -f "$compose_file" -p "httparena-$framework-$profile" \
        ps --services 2>/dev/null
}
