FROM php:8.6-cli-alpine AS extensions
RUN docker-php-ext-install pcntl

FROM extensions AS dependencies
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
WORKDIR /app
ARG THESIS_REV=2b2bc1126676f5dd288f0403976fab863c8838aa
RUN apk add --no-cache git \
    && git init -q thesis \
    && git -C thesis fetch --depth=1 https://github.com/thesis-php/thesis.git "${THESIS_REV}" \
    && git -C thesis checkout -q --detach "${THESIS_REV}"
COPY composer.json composer.lock ./
RUN composer install --prefer-source --no-dev --no-interaction --no-plugins --no-scripts --classmap-authoritative \
    && find vendor -name .git -prune -exec rm -rf {} +

FROM php:8.6-cli-alpine
COPY --from=extensions /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=extensions /usr/local/etc/php/conf.d/docker-php-ext-pcntl.ini /usr/local/etc/php/conf.d/
WORKDIR /app
COPY --from=dependencies /app/vendor ./vendor
COPY server.php start.sh ./
EXPOSE 8080 8081
CMD ["sh", "start.sh"]
