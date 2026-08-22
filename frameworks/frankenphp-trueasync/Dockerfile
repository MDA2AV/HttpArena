FROM trueasync/php-true-async:latest-frankenphp

WORKDIR /app

COPY worker.php /app/worker.php
COPY Caddyfile /etc/caddy/Caddyfile

# OPcache JIT tuning
RUN echo '\
opcache.enable=1\n\
opcache.enable_cli=1\n\
opcache.jit=1255\n\
opcache.jit_buffer_size=128M\n\
opcache.memory_consumption=256\n\
opcache.max_accelerated_files=10000\n\
opcache.validate_timestamps=0\n\
memory_limit=512M\n\
' >> /etc/php.d/99-benchmark.ini

ENV GODEBUG=cgocheck=0

# GC tuning: GOGC=1000 reduces GC frequency ~10x, cutting stop-the-world
# overhead on this allocation-heavy workload (+46% throughput on /baseline11).
ENV GOGC=1000

# For cgo-heavy workloads GOMAXPROCS should be over-provisioned past numCPU
# (roughly 2x num_cpu) to avoid runtime.stopm futex churn on cgo returns.
# See PERFORMANCE_NOTES.md. Left unset here so the benchmark operator can
# tune per-host (e.g. GOMAXPROCS=128 on 64-core HttpArena hardware).

EXPOSE 8080
EXPOSE 8443

CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
