FROM dunglas/frankenphp:latest

COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

RUN install-php-extensions pcntl opcache zip

WORKDIR /app

COPY composer.json ./
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-scripts

COPY . .
RUN mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache

# post_max_size unlimited so the 20 MB upload profile is not rejected, opcache
# with timestamp validation off as the Laravel deployment guide recommends.
COPY php.ini $PHP_INI_DIR/conf.d/99-httparena.ini

ENV APP_ENV=production \
    APP_DEBUG=false \
    APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= \
    LOG_CHANNEL=null \
    SERVER_NAME=:8080

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 8081
CMD ["/usr/local/bin/entrypoint.sh"]
