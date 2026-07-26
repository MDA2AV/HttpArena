FROM trueasync/php-true-async:0.7.0-beta.5-php8.6-alpine

RUN apk add --no-cache git openssh-client

RUN printf '%s\n' \
      'opcache.jit=1255' \
      'opcache.jit_buffer_size=128M' \
      'opcache.memory_consumption=256' \
      'opcache.max_accelerated_files=10000' \
      'opcache.validate_timestamps=0' \
      'memory_limit=1024M' \
    > /etc/php.d/99-arena.ini

# Install composer
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

WORKDIR /app

COPY composer.json ./

ENV COMPOSER_IPRESOLVE=4
ENV COMPOSER_PROCESS_TIMEOUT=2000
RUN APP_ENV=prod COMPOSER_MAX_PARALLEL_HTTP=1 composer install --no-dev --optimize-autoloader --no-scripts --no-interaction --prefer-dist

COPY . .

RUN APP_ENV=prod APP_DEBUG=0 APP_SECRET=benchmark \
    DATABASE_URL=pgsql://bench:bench@localhost:5432/benchmark \
    DEFAULT_URI=http://localhost \
    php bin/console cache:warmup || true

EXPOSE 8080 8443

CMD ["php", "/app/public/index.php"]
