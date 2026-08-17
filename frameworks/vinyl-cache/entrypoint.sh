#!/bin/sh
set -e

exec vinyld -F \
    -a :8080 \
    -f /etc/vinyl/default.vcl \
    -s malloc,256m
