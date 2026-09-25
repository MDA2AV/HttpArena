#!/bin/bash
# The mounted certificate pair copied to where the server wants a private key (0600), then
# one agensio process with the arena's four listeners; workers = 0 counts the cpuset's CPUs.
set -eu
mkdir -p /run/agensio /srv/www
install -m 0600 /certs/server.key /run/agensio/server.key
install -m 0644 /certs/server.crt /run/agensio/server.crt
exec agensio -c /etc/agensio/agensio.toml
