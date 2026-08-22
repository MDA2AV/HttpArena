FROM dunglas/frankenphp:latest

COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

RUN install-php-extensions opcache zip

WORKDIR /app

COPY composer.json ./
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-scripts

COPY public ./public

# post_max_size unlimited so the 20 MB upload profile is not rejected, opcache
# with timestamp validation off as a PHP deployment would run it.
COPY php.ini $PHP_INI_DIR/conf.d/99-httparena.ini
COPY Caddyfile /etc/caddy/Caddyfile
COPY json-tls.caddy /etc/caddy/json-tls.caddy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /etc/caddy/tls.d && chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080
CMD ["/usr/local/bin/entrypoint.sh"]
