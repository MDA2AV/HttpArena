FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# ioma library source (provided via build context) plus the baseline handler.
COPY include/ include/
COPY src/ src/
COPY third_party/ third_party/
COPY main.c .

# No liburing: ioma issues io_uring syscalls directly. One translation unit set, one binary.
RUN gcc -O2 -march=native -Wall -std=gnu11 -pthread \
        -Iinclude -Ithird_party/picohttpparser \
        main.c src/*.c src/*.S third_party/picohttpparser/picohttpparser.c \
        -o server -pthread

FROM ubuntu:24.04
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server", "64"]
