FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Stock Debian Apache 2.4. mod_lua.so ships with apache2-bin on Debian 12 —
# no separate libapache2-mod-lua package.
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# We load all needed modules explicitly from httpd.conf, so purge the
# distro's default site/mod/conf wiring to keep the image deterministic.
RUN rm -rf /etc/apache2/sites-enabled/* \
           /etc/apache2/conf-enabled/* \
           /etc/apache2/mods-enabled/* \
           /etc/apache2/apache2.conf \
           /etc/apache2/ports.conf

# Drop in our config + lua handlers.
COPY httpd.conf     /etc/apache2/httpd.conf
COPY baseline11.lua /etc/apache2/baseline11.lua
COPY pipeline.lua   /etc/apache2/pipeline.lua

# Runtime dirs that Apache expects.
RUN mkdir -p /var/run/apache2 /var/lock/apache2 /var/log/apache2 && \
    chown -R www-data:www-data /var/run/apache2 /var/lock/apache2 /var/log/apache2

EXPOSE 8080

# Apache needs a few envvars defined; /etc/apache2/envvars is the normal
# shell-sourced file but we pass the equivalents directly and start with
# apache2ctl in foreground, pointing explicitly at our config.
ENV APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_PID_FILE=/var/run/apache2/apache2.pid \
    APACHE_RUN_DIR=/var/run/apache2 \
    APACHE_LOCK_DIR=/var/lock/apache2 \
    APACHE_LOG_DIR=/var/log/apache2

CMD ["apache2", "-D", "FOREGROUND", "-f", "/etc/apache2/httpd.conf"]
