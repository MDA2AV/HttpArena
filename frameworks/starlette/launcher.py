import os
import sys


def get_cpu_count():
    # cgroup quota first: a container capped at N cores must not start one
    # worker per host core. Same rule koa's getCPUCount uses.
    try:
        with open("/sys/fs/cgroup/cpu.max") as cpu_max:
            quota, period = cpu_max.read().strip().split(" ")
        if quota != "max":
            cgroup = int(int(quota) // int(period))
            if cgroup >= 1:
                return cgroup
    except Exception:
        pass
    return len(os.sched_getaffinity(0))


if len(sys.argv) < 2:
    print("Usage: launcher.py <program> [args...]", file=sys.stderr)
    sys.exit(1)

WRK_COUNT = max(min(get_cpu_count(), 128), 4)

args = sys.argv[1:]
if "--workers" not in args:
    args += ["--workers", str(WRK_COUNT)]

# exec, so uvicorn is PID 1 and gets the stop signal itself
os.execvp(args[0], args)
