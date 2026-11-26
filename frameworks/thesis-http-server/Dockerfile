FROM php:8.6-cli-alpine AS extensions
RUN docker-php-ext-install pcntl

FROM extensions AS dependencies
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
WORKDIR /app
ARG THESIS_REV=2b2bc1126676f5dd288f0403976fab863c8838aa
RUN mkdir thesis \
    && curl -fsSL --retry 3 "https://codeload.github.com/thesis-php/thesis/tar.gz/${THESIS_REV}" -o /tmp/thesis.tar.gz \
    && tar -xzf /tmp/thesis.tar.gz -C thesis --strip-components=1
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-plugins --no-scripts --classmap-authoritative

FROM php:8.6-cli-alpine
COPY --from=extensions /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=extensions /usr/local/etc/php/conf.d/docker-php-ext-pcntl.ini /usr/local/etc/php/conf.d/
WORKDIR /app
COPY --from=dependencies /app/vendor ./vendor
COPY server.php start.sh ./
EXPOSE 8080 8081
CMD ["sh", "start.sh"]
