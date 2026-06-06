FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y gcc make git libc6-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch liburing-2.9 https://github.com/axboe/liburing.git /tmp/liburing \
    && cd /tmp/liburing && ./configure && make -C src -j"$(nproc)" && make -C src install && ldconfig \
    && rm -rf /tmp/liburing
WORKDIR /app
COPY main.c .
RUN gcc -O3 -march=native -pthread -Wall -o server main.c -luring

FROM ubuntu:24.04
COPY --from=build /usr/lib/liburing.so.2.9 /usr/lib/
RUN ln -s /usr/lib/liburing.so.2.9 /usr/lib/liburing.so.2 && ldconfig
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server", "64"]
