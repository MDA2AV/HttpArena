FROM envoyproxy/envoy:v1.30-latest

COPY envoy.yaml /etc/envoy/envoy.yaml

EXPOSE 8080

# --concurrency must match the benchmark cpuset (scripts/lib/profiles.sh:
# "0-31,64-95" = 64 logical CPUs for infrastructure-tier profiles). Envoy's
# --concurrency 0 means "zero worker threads; serve on the main dispatcher",
# which pins throughput to a single core regardless of cpuset width.
CMD ["envoy", "-c", "/etc/envoy/envoy.yaml", "--concurrency", "64"]
