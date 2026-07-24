import os
import sys
import multiprocessing
import gunicorn


_CPU_COUNT = int(multiprocessing.cpu_count())
_WRK_COUNT = min(len(os.sched_getaffinity(0)), 128)
_WRK_COUNT = max(_WRK_COUNT, 4)


bind = "0.0.0.0:8080"
workers = _WRK_COUNT
keepalive = 120
loglevel = 'critical'
accesslog = None
errorlog = "-"
disable_redirect_access_to_syslog = True
pidfile = "gunicorn.pid"
worker_class = "sync"

gunicorn.SERVER_SOFTWARE = "Flask"
os.environ["SERVER_SOFTWARE"] = "Flask"
