FROM ubuntu:26.04

ENV PROCESS_MULTIPLIER=1
ENV EVENT_LOOP=Select

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -yqq && apt-get install -yqq software-properties-common > /dev/null
RUN apt-get update -yqq > /dev/null && apt-get upgrade -yqq > /dev/null

RUN apt-get install -yqq zip unzip php8.5-cli php8.5-xml php8.5-zip> /dev/null

COPY --from=composer/composer:latest-bin --link /composer /usr/local/bin/composer

RUN apt-get install -y php-pear php8.5-dev libevent-dev git > /dev/null && \
    pecl install event-3.1.4 > /dev/null && echo "extension=event.so" > /etc/php/8.5/cli/conf.d/30-event.ini

WORKDIR /workerman
COPY --link composer.json .
RUN composer install --optimize-autoloader --classmap-authoritative --no-dev --quiet
COPY php.ini /etc/php/8.5/cli/php.ini

COPY --link . .

EXPOSE 8080

CMD ["php", "/workerman/ws.php", "start"]
