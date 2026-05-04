FROM ubuntu:24.04

# Minimal runtime deps:
#   libnghttp2-14  — system nghttp2 (.so linked by true_async_server.so)
#   libsqlite3-0   — PDO sqlite (built into PHP)
#   ca-certificates — TLS cert store
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libnghttp2-14 \
        libsqlite3-0 \
        libpq5 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── PHP binary (locally built, ZTS + TrueAsync ABI) ─────────────────
COPY php /usr/local/bin/php

# ── Custom shared libraries (libuv, OpenSSL 3, ngtcp2, nghttp3) ──────
COPY libs/ /usr/local/lib/
RUN ldconfig

# ── PHP extension dir + true_async_server.so ─────────────────────────
RUN mkdir -p /usr/local/lib/php/extensions/no-debug-zts-20250926
COPY true_async_server.so /usr/local/lib/php/extensions/no-debug-zts-20250926/true_async_server.so
COPY pdo_pgsql.so        /usr/local/lib/php/extensions/no-debug-zts-20250926/pdo_pgsql.so

# ── Minimal php.ini ───────────────────────────────────────────────────
RUN mkdir -p /usr/local/lib && printf '%s\n' \
      'extension_dir=/usr/local/lib/php/extensions/no-debug-zts-20250926' \
      'extension=pdo_pgsql' \
      'extension=true_async_server' \
      'opcache.enable=1' \
      'opcache.enable_cli=1' \
      'opcache.jit=1255' \
      'opcache.jit_buffer_size=128M' \
      'opcache.memory_consumption=256' \
      'opcache.max_accelerated_files=10000' \
      'opcache.validate_timestamps=0' \
      'opcache.preload=' \
      'memory_limit=1024M' \
      'realpath_cache_size=4M' \
      'realpath_cache_ttl=600' \
    > /usr/local/lib/php.ini

# ── Application ───────────────────────────────────────────────────────
WORKDIR /app
COPY entry.php /app/entry.php
COPY PostgreSQL.php /app/PostgreSQL.php

EXPOSE 8080
EXPOSE 8443

CMD ["php", "/app/entry.php"]
