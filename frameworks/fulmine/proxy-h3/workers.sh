#!/bin/sh
# One nginx worker per CPU of the container's cpuset: nproc honours it, `auto` may count the host.
sed -i "s/^worker_processes .*/worker_processes $(nproc);/" /etc/nginx/nginx.conf
