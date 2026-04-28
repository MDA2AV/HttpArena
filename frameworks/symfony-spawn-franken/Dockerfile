FROM trueasync/php-true-async:latest-frankenphp

COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

WORKDIR /app

COPY composer.json ./

RUN APP_ENV=prod composer install --no-dev --optimize-autoloader --no-scripts --no-interaction

COPY . .

RUN APP_ENV=prod APP_DEBUG=0 APP_SECRET=benchmark \
    DATABASE_URL=pgsql://bench:bench@localhost:5432/benchmark \
    DEFAULT_URI=http://localhost \
    php bin/console cache:warmup

RUN echo '\
opcache.enable=1\n\
opcache.enable_cli=1\n\
opcache.jit=1255\n\
opcache.jit_buffer_size=128M\n\
opcache.memory_consumption=256\n\
opcache.max_accelerated_files=10000\n\
opcache.validate_timestamps=0\n\
memory_limit=2048M\n\
' >> /etc/php.d/99-benchmark.ini

ENV GODEBUG=cgocheck=0
ENV GOGC=1000
ENV APP_ENV=prod
ENV APP_DEBUG=0
ENV APP_SECRET=benchmark
ENV DATABASE_URL=pgsql://bench:bench@localhost:5432/benchmark
ENV DEFAULT_URI=http://localhost

COPY Caddyfile /etc/caddy/Caddyfile

EXPOSE 8080 8443/tcp 8443/udp

CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
