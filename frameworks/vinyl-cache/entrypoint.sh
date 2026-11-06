#!/bin/sh
set -e

# Adapting to the benchmark hardware as per
# https://www.http-arena.com/docs/add-framework/implementation-rules/frameworks/standard/
# thread_pools: https://www.http-arena.com/docs/hardware/
# 	32 physical cores available for server
# min/max: 4096 connections / 32 pools = 128, double for max
exec vinyld -F \
    -a :8080 \
    -f /etc/vinyl/default.vcl \
    -s malloc,256m \
    -p vsl_mask=none \
    -p thread_pools=32 \
    -p thread_pool_min=128 \
    -p thread_pool_max=256
