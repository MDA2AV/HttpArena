FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -yqq && apt-get install -yqq software-properties-common >/dev/null

RUN LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php >/dev/null && \
    LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/nginx >/dev/null && \
    apt-get update -yqq > /dev/null && apt-get upgrade -yqq >/dev/null && \
    apt-get install -yqq wget git libxml2-dev systemtap-sdt-dev nginx-extras \
                    zlib1g-dev libpcre3-dev libargon2-dev libsodium-dev libkrb5-dev \
                    php8.5-fpm php8.5-cli php8.5-pgsql >/dev/null

COPY conf/* /etc/php/8.5/fpm/
COPY src/ src/
COPY nginx.conf .

EXPOSE 8080 8443/tcp 8443/udp

#ENTRYPOINT ["php", "src/json.php"]

CMD php src/json.php && \
    service php8.5-fpm start && \
    nginx -c /nginx.conf
