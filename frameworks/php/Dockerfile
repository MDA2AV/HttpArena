ARG NGINX_VERSION=1.31.4

# nginx is built from source here rather than installed from a repository.
# This entry used to take it from ppa:ondrej/nginx, which no longer exists —
# `add-apt-repository ppa:ondrej/nginx` now fails with "ppa not found", and the
# build died on that line. ondrej's packaging moved to packages.sury.org, which
# publishes php but no nginx, and Ubuntu's own nginx has no --with-http_v3_module,
# which the baseline-h3 and static-h3 profiles need: nginx.conf asks for
# `listen 8443 quic` and stock nginx rejects the directive at startup.
#
# Debian trixie's OpenSSL is 3.5, which carries the QUIC API http_v3 builds
# against, so no separate quictls is needed — the same approach frameworks/nginx
# already uses.
FROM debian:trixie AS build

RUN apt-get update -yqq && apt-get install -yqq --no-install-recommends \
    build-essential libpcre2-dev libssl-dev zlib1g-dev wget ca-certificates >/dev/null

ARG NGINX_VERSION
WORKDIR /tmp
RUN wget -q https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz

WORKDIR /tmp/nginx-${NGINX_VERSION}
RUN ./configure \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-http_gzip_static_module \
        --with-cc-opt="-O3 -DNDEBUG" >/dev/null && \
    make -j"$(nproc)" >/dev/null

FROM debian:trixie

ARG DEBIAN_FRONTEND=noninteractive

# php 8.5 from packages.sury.org — the repository ppa:ondrej/php now announces
# itself as being merged into, and the only one still carrying 8.5 for a distro
# whose OpenSSL can build http_v3.
RUN apt-get update -yqq && \
    apt-get install -yqq --no-install-recommends ca-certificates curl >/dev/null && \
    curl -sSLo /tmp/sury.gpg https://packages.sury.org/php/apt.gpg && \
    install -D -m 0644 /tmp/sury.gpg /etc/apt/keyrings/sury-php.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ trixie main" \
        > /etc/apt/sources.list.d/sury-php.list && \
    apt-get update -yqq && \
    apt-get install -yqq --no-install-recommends \
        libpcre2-8-0 php8.5-fpm php8.5-cli php8.5-pgsql \
        php8.5-redis php-twig >/dev/null && \
    rm -rf /var/lib/apt/lists/* /tmp/sury.gpg

ARG NGINX_VERSION
COPY --from=build /tmp/nginx-${NGINX_VERSION}/objs/nginx /usr/sbin/nginx
# The source build has no `make install`, so the prefix nginx writes into has to
# exist: logs, and the body/proxy temp paths it opens on first use.
RUN mkdir -p /usr/local/nginx/logs /var/log/nginx \
             /var/lib/nginx/body /var/lib/nginx/proxy /var/lib/nginx/fastcgi && \
    chown -R www-data:www-data /var/lib/nginx /var/log/nginx

COPY conf/* /etc/php/8.5/fpm/
COPY src/ src/
COPY views/ views/
COPY nginx.conf .

EXPOSE 8080 8443/tcp 8443/udp

# php-fpm is started by its binary rather than `service`: this image has no init
# system, and the packaged unit is not what runs here.
CMD php src/json.php && \
    php-fpm8.5 --fpm-config /etc/php/8.5/fpm/php-fpm.conf --daemonize && \
    nginx -c /nginx.conf
