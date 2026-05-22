#!/bin/sh
# Enable SO_REUSEPORT for all TCP sockets via LD_PRELOAD shim.
# Dart's HttpServer.bind(shared:true) only shares within one process; the shim
# makes cross-process port sharing work so each worker gets its own
# EventHandler thread and the kernel distributes connections evenly.
export LD_PRELOAD=/lib/reuseport_shim.so

n="${WORKERS:-$(nproc)}"
port="${PORT:-8080}"
echo "[dart-io] spawning $n dart processes on port $port (nproc=$n)"

# Spawn N independent OS processes, each running a single isolate.
# Each process gets its own Dart VM EventHandler (kqueue/epoll thread),
# so I/O scales linearly with CPU count — the same model as Node.js cluster.
# The LD_PRELOAD shim above ensures SO_REUSEPORT is set so the kernel
# distributes incoming connections evenly across all N processes.
for i in $(seq 1 $((n - 1))); do
    /server/bin/benchmark_http_server "$port" &
done

# Last worker runs in the foreground as PID 1 so Docker signals reach it.
exec /server/bin/benchmark_http_server "$port"
