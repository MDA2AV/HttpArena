FROM suyar/hyperf-swoole:6.2.0

ENV SCAN_CACHEABLE=true
ENV COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /www

COPY app/ /www/app/
COPY bin/ /www/bin/
COPY config/ /www/config/
COPY composer.json /www/
COPY 50_overrides.ini $PHP_INI_SCAN_DIR/50_overrides.ini

COPY --from=composer /usr/bin/composer /usr/local/bin/composer

RUN set -eux; \
    composer install --optimize-autoloader --no-dev

EXPOSE 8080

CMD ["php", "/www/bin/hyperf.php", "start"]
