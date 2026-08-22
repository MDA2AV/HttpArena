#!/bin/sh
# json-tls on 8081. Octane's Caddyfile carries a {$CADDY_EXTRA_CONFIG}
# placeholder that Octane itself never sets, so Caddy resolves it from the
# environment -- which is where the TLS site goes. Same worker, same app as
# 8080; only the listener differs.
#
# It has to be conditional: Caddy refuses to start when a tls directive points
# at files that are not there, and the harness mounts /certs only for the TLS
# profiles.
set -e

if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
    CADDY_EXTRA_CONFIG=':8081 {
	tls /certs/server.crt /certs/server.key
	route {
		root * /app/public
		encode zstd br gzip
		php_server {
			index frankenphp-worker.php
			try_files {path} frankenphp-worker.php
			resolve_root_symlink
		}
	}
}'
    export CADDY_EXTRA_CONFIG
fi

exec php artisan octane:start --server=frankenphp --host=0.0.0.0 --port=8080 --admin-port=2019
