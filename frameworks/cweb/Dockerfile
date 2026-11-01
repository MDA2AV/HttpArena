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
    zlib1g-dev \
    libbrotli-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ln -svf /usr/include/postgresql/* /usr/include

# Bust cache when Bitbucket repo updates
ADD https://api.bitbucket.org/2.0/repositories/saadalabeed/cweb/commits?pagelen=1 /tmp/git_ver

RUN git clone https://bitbucket.org/saadalabeed/cweb.git /tmp/cweb \
    && cd /tmp/cweb \
    && make clean && make \
    && make install

WORKDIR /build
COPY app.c /build/app.c
RUN gcc -O3 -march=native -flto -Wall -Wextra -std=gnu99 app.c \
    -lcweb -luring -lpq -lseccomp -lz -lbrotlienc -o /build/app

# -------------------------------------------------------------
# Stage 2: Minimal Runtime Container
# -------------------------------------------------------------
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    liburing2 \
    libpq5 \
    libseccomp2 \
    zlib1g \
    libbrotli1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /data/static /var/www && ln -sf /data/static /var/www/static

COPY --from=builder /usr/lib/libcweb.so /usr/lib/libcweb.so
COPY --from=builder /build/app /app_bin
RUN ldconfig

WORKDIR /

EXPOSE 8080
USER root

ENTRYPOINT ["/app_bin"]
