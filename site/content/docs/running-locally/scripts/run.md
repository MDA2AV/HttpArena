---
title: run.sh
weight: 2
---

Run a framework's Docker container interactively for manual testing. Builds the image, starts a Postgres sidecar, mounts all data volumes, and streams container logs until you press Ctrl+C.

```bash
./scripts/run.sh <framework>
```

## What it does

1. Builds the Docker image for the framework (or runs `build.sh` if one exists)
2. Starts a Postgres sidecar container with the seeded benchmark database
3. Mounts all data files unconditionally — datasets, static files, TLS certs
4. Sets `DATABASE_URL` and `DATABASE_MAX_CONN` environment variables
5. Runs the container attached so logs stream to your terminal
6. Cleans up all containers on exit (Ctrl+C or script termination)

## Options

| Parameter | Description |
|-----------|-------------|
| `<framework>` | Name of the framework directory under `frameworks/` |
| `PORT` env var | Override HTTP port (default: 8080) |
| `H2PORT` env var | Override HTTPS/H2 port (default: 8443) |

## Networking

Uses `--network host` so the container binds directly to the host's network interfaces. No port mapping is needed — the framework listens on ports 8080 and 8443 directly.

## Example

```bash
./scripts/run.sh express

# In another terminal:
curl http://localhost:8080/baseline11?a=1&b=2
curl http://localhost:8080/json/5?m=3
curl http://localhost:8080/async-db?min=10&max=50&limit=20
```
