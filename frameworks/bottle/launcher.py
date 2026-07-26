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

args = sys.argv[1:]     # [ "gunicorn", "--config", "gunicorn_conf.py", "app:app" ]

def run_prog(args: list, ssl: bool = False):
    config_idx = 0
    try:
        config_idx = args.index("--config") + 1
        base_config = args[config_idx]
    except Exception:
        config_idx = 0
        base_config = ''
    cmd = list(args)
    if ssl and (config_idx == 0 or not base_config):
        return None
    if ssl:
        cmd[config_idx] = 'gunicorn_conf_ssl.py'
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

