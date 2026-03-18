import os

bind = "0.0.0.0:8080"
workers = len(os.sched_getaffinity(0)) * 2
worker_class = "uvicorn.workers.UvicornWorker"
keepalive = 120
