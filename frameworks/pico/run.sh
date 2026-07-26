#!/bin/sh
# picoev is a single-threaded event loop; scale across cores by launching one
# process per core, all sharing the listen socket via SO_REUSEPORT.
for i in $(seq 0 $(($(nproc --all)-1))); do
  taskset -c $i /server &
done
wait
