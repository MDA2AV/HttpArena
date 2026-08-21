import os
import sys
import multiprocessing
import subprocess
import signal
import time


CPU_COUNT = int(multiprocessing.cpu_count())
WRK_COUNT = min(len(os.sched_getaffinity(0)), 128)
WRK_COUNT = max(WRK_COUNT, 4)


if len(sys.argv) < 2:
    print("Usage: launcher.py <program> [args...]", file=sys.stderr)
    sys.exit(1)

args = sys.argv[1:]     # [ "uvicorn", "run", "app:app", "--port", "8080" ]

def run_prog(args: list, ssl: bool = False):
    port_idx = 0
    try:
        port_idx = args.index("--port") + 1
        base_port = int(args[port_idx])
    except Exception:
        port_idx = 0
        base_port = 0
    cmd = list(args)
    if ssl and (port_idx == 0 or base_port == 0):
        return None
    if ssl:
        cmd[port_idx] = str(base_port + 1)  # 8081
    if "--workers" not in cmd:
        cmd += [ "--workers", str(WRK_COUNT) ]
    if ssl:
        cmd += [ "--ssl-certfile", os.environ.get("TLS_CERT", "/certs/server.crt") ]
        cmd += [ "--ssl-keyfile" , os.environ.get("TLS_KEY" , "/certs/server.key") ]
    return subprocess.Popen(cmd)


http_proc = run_prog(args)

https_proc = run_prog(args, ssl = True)

def shutdown(sig, frame):
    http_proc.terminate()
    https_proc.terminate() if https_proc else None
    time.sleep(1)
    if http_proc.poll() is None:
        http_proc.kill()
    if https_proc and https_proc.poll() is None:
        https_proc.kill()
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

try:
    http_proc.wait()
    https_proc.terminate() if https_proc else None
except Exception:
    pass

