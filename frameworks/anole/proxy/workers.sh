#!/bin/sh
# One nginx worker per CPU of this container's cpuset. `worker_processes auto`
# counts the host's CPUs and ignores the cpuset; nproc honours it.
sed -i "s/^worker_processes .*/worker_processes $(nproc);/" /etc/nginx/nginx.conf
