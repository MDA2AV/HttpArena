import os
import sys
import multiprocessing


CPU_COUNT = int(multiprocessing.cpu_count())
WRK_COUNT = min(len(os.sched_getaffinity(0)), 128)
WRK_COUNT = max(WRK_COUNT, 4)


if len(sys.argv) < 2:
    print("Usage: launcher.py <program> [args...]", file=sys.stderr)
    sys.exit(1)

args = sys.argv[1:]

prog = args[0]

if '--processes' not in args:
    args += [ "--processes", str(WRK_COUNT) ]

if '--workers' not in args:
    args += [ "--workers", "2" ]

if '/' in prog:
    os.execv(prog, args)
else:
    os.execvp(prog, args)
