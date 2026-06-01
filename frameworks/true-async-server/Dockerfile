FROM trueasync/php-true-async:0.7.0-rc.6-php8.6

RUN printf '%s\n' \
      'opcache.jit=1255' \
      'opcache.jit_buffer_size=128M' \
      'opcache.memory_consumption=256' \
      'opcache.max_accelerated_files=10000' \
      'opcache.validate_timestamps=0' \
      'memory_limit=1024M' \
    > /etc/php.d/99-arena.ini \
 && rm -f /etc/php.d/xdebug.ini

WORKDIR /app
COPY entry.php PostgreSQL.php SQLite.php /app/

EXPOSE 8080 8443 8443/udp

CMD ["php", "/app/entry.php"]
