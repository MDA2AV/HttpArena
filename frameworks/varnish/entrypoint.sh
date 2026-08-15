#!/bin/sh
set -e

exec varnishd -F \
    -a :8080 \
    -A /etc/varnish/tls.conf \
    -f /etc/varnish/default.vcl \
    -p feature=+http2 \
    -s malloc,256m
