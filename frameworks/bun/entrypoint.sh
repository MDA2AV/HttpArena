#!/bin/sh
# One server process per CPU the container may use, all sharing port 8080.
# nproc already follows --cpuset-cpus, which is how the profiles limit CPU, but
# not a --cpus quota, so read the cgroup too and keep the smaller of the two.
CPUS=$(nproc)
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r QUOTA PERIOD < /sys/fs/cgroup/cpu.max
  if [ "$QUOTA" != "max" ]; then
    LIMIT=$((QUOTA / PERIOD))
    [ "$LIMIT" -ge 1 ] && [ "$LIMIT" -lt "$CPUS" ] && CPUS=$LIMIT
  fi
fi

for i in $(seq 1 "$CPUS"); do
  bun run /app/server.ts &
done
wait
