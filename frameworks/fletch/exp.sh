#!/bin/bash
set -e

echo "=== Test B: multi-process (N processes x 1 isolate, N EventHandlers) ==="
for N in 1 2 3 4 5 6; do
  docker rm -f fletch-test 2>/dev/null || true
  docker run -d --name fletch-test --cpus=6 -p 8080:8080 -e WORKERS=$N httparena-fletch
  sleep 3
  wrk -t2 -c256 -d10s http://localhost:8080/pipeline 2>/dev/null | grep "Requests/sec"
  echo "^ multi-process N=$N"
  docker rm -f fletch-test 2>/dev/null || true
  sleep 1
done
