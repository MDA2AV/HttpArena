#!/bin/sh
CPUS=$(nproc)
if [ -f /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max
  if [ "$quota" != "max" ]; then
    CGROUP_CPUS=$((quota / period))
    [ "$CGROUP_CPUS" -lt 1 ] && CGROUP_CPUS=1
    [ "$CGROUP_CPUS" -lt "$CPUS" ] && CPUS=$CGROUP_CPUS
  fi
fi
# Every process opens its own Postgres pool, so the server has to know how many
# of them there are to keep the total under the server's max_connections.
export HTTPARENA_PROCS="$CPUS"
for i in $(seq 1 "$CPUS"); do
  bun run /app/server.ts &
done
wait
