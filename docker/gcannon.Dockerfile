FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y gcc make git && rm -rf /var/lib/apt/lists/*
WORKDIR /deps
RUN git clone --branch liburing-2.9 --depth 1 https://github.com/axboe/liburing.git && \
    cd liburing && ./configure --prefix=/usr && make -j$(nproc) -C src && make install -C src
WORKDIR /build
COPY . .
RUN make clean && make -j$(nproc)

FROM ubuntu:24.04
COPY --from=build /usr/lib/liburing.so.2.9 /usr/lib/liburing.so.2.9
RUN ln -s liburing.so.2.9 /usr/lib/liburing.so.2 && ln -s liburing.so.2 /usr/lib/liburing.so && \
    ldconfig
COPY --from=build /build/gcannon /usr/local/bin/gcannon
ENTRYPOINT ["gcannon"]
