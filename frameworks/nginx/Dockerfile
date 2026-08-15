ARG NGINX_VERSION=1.30.0

FROM debian:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpcre2-dev zlib1g-dev wget ca-certificates git perl cmake

# Build quictls (OpenSSL fork with QUIC support). Pinned to the same tag as
# docker/h2load-h3.Dockerfile — the 3.1.5+quic branch this used to track no
# longer configures on current bookworm (perl aborts in Configure).
WORKDIR /tmp
RUN git clone --depth 1 -b openssl-3.3.0-quic1 https://github.com/quictls/openssl.git quictls && \
    cd quictls && \
    ./config --prefix=/opt/quictls --libdir=lib no-tests && \
    make -j$(nproc) && \
    make install_sw

# Download nginx source
ARG NGINX_VERSION
RUN wget -q http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar xzf nginx-${NGINX_VERSION}.tar.gz

# Add ngx_brotli
RUN git clone --recurse-submodules -j8 https://github.com/google/ngx_brotli && \
    cd ngx_brotli/deps/brotli  && \
    mkdir out && cd out  && \
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-Ofast -m64 -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_CXX_FLAGS="-Ofast -m64 -march=native -mtune=native -flto -funroll-loops -ffunction-sections -fdata-sections -Wl,--gc-sections" -DCMAKE_INSTALL_PREFIX=./installed .. && \
    cmake --build . --config Release --target brotlienc  && \
    cd ../../../..

# Copy module
COPY ngx_http_httparena_module.c config /tmp/module/

# Build nginx with custom module + HTTP/3
WORKDIR /tmp/nginx-${NGINX_VERSION}
RUN ./configure \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_gzip_static_module \
    --add-module=/tmp/ngx_brotli \
    --add-module=/tmp/module \
    --with-cc-opt="-O3 -march=native -DNDEBUG -I/opt/quictls/include" \
    --with-ld-opt="-lm -L/opt/quictls/lib -Wl,-rpath,/opt/quictls/lib" && \
    make -j$(nproc)

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcre2-8-0 && \
    rm -rf /var/lib/apt/lists/*
# Copy the install tree rather than naming versioned sonames: make install_sw
# already lays down the right symlinks, and hand-written ones broke the moment
# the quictls pin moved.
COPY --from=build /opt/quictls/lib/ /opt/quictls/lib/
RUN ldconfig /opt/quictls/lib
ARG NGINX_VERSION
COPY --from=build /tmp/nginx-${NGINX_VERSION}/objs/nginx /usr/sbin/nginx
RUN mkdir -p /usr/local/nginx/logs

COPY nginx.conf /usr/local/nginx/conf/nginx.conf

EXPOSE 8080 8081 8443/tcp 8443/udp

CMD ["nginx"]
