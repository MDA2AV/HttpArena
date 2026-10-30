# -------------------------------------------------------------
# Stage 1: Clone & Build CWEB + Benchmark App from Source
# -------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    git \
    liburing-dev \
    libpq-dev \
    libseccomp-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# For debian, this symlink is a must to avoid compilation error
RUN ln -svf /usr/include/postgresql/* /usr/include

# 1. Clone CWEB from Bitbucket and install libcweb.so + headers
RUN git clone https://bitbucket.org/saadalabeed/cweb.git /tmp/cweb \
    && cd /tmp/cweb \
    && make clean && make \
    && make install

# 2. Compile HttpArena benchmark app
WORKDIR /build
COPY app.c /build/app.c
RUN gcc -O3 -march=native -flto -Wall -Wextra -std=gnu99 app.c \
    -lcweb -luring -lpq -lseccomp -o /build/app

# -------------------------------------------------------------
# Stage 2: Minimal Runtime Container
# -------------------------------------------------------------
FROM mirror.gcr.io/library/ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    liburing2 \
    libpq5 \
    libseccomp2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Ensure both /data/static and /var/www/static paths work
RUN mkdir -p /data/static /var/www && ln -sf /data/static /var/www/static

COPY --from=builder /usr/lib/libcweb.so /usr/lib/libcweb.so
COPY --from=builder /build/app /app_bin
RUN ldconfig

# CRITICAL: WORKDIR / ensures chroot(".") jails into container root "/"
WORKDIR /

EXPOSE 8080
USER root

ENTRYPOINT ["/app_bin"]
