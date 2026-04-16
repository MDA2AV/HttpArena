# scripts/lib/postgres.sh — Postgres sidecar lifecycle for async-db and
# api-{4,16} tests. Single well-known container name, host networking,
# persistent init from data/pgdb-seed.sql.
#
# Matches the original benchmark.sh setup exactly — `-c max_connections=256`
# passed on the command line rather than mounting a custom config file.

postgres_start() {
    info "starting postgres sidecar"

    # -v on the rm is load-bearing: without it, the anonymous volume
    # postgres:17-alpine creates for /var/lib/postgresql/data survives
    # even after the container is gone, and every benchmark run leaks
    # a fresh ~70MB dataset. Over dozens of runs that silently grows
    # into tens of GB of dangling volumes.
    docker rm -f -v "$PG_CONTAINER" 2>/dev/null || true

    # --rm so the container self-cleans on stop. Also pass --tmpfs for
    # the data dir so postgres writes the seed + WAL to RAM instead of
    # an anonymous volume — faster startup AND no storage leak path.
    docker run -d --rm --name "$PG_CONTAINER" --network host \
        --tmpfs /var/lib/postgresql/data:rw,size=2g \
        -e POSTGRES_USER=bench \
        -e POSTGRES_PASSWORD=bench \
        -e POSTGRES_DB=benchmark \
        -v "$DATA_DIR/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro" \
        postgres:17-alpine \
        -c max_connections=256 >/dev/null

    # Wait for postgres to accept queries AND for the seed script to finish.
    # Readiness check uses `SELECT 1 FROM items LIMIT 1` — the items table
    # is created + populated by the entrypoint seed, so this covers both
    # "daemon ready" and "seed complete" in one probe.
    local i
    for i in $(seq 1 60); do
        if docker exec "$PG_CONTAINER" pg_isready -U bench -d benchmark >/dev/null 2>&1; then
            if docker exec "$PG_CONTAINER" psql -U bench -d benchmark -tAc \
                'SELECT 1 FROM items LIMIT 1' 2>/dev/null | grep -q 1; then
                info "postgres ready (seeded)"
                return 0
            fi
        fi
        sleep 1
    done

    fail "postgres sidecar did not become ready within 60s"
}

postgres_stop() {
    # -v for the same reason as postgres_start: nuke any attached
    # anonymous volumes along with the container.
    docker rm -f -v "$PG_CONTAINER" 2>/dev/null || true
}
