FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make curl ca-certificates libc6-dev apache2-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Build libioma from its own repo, pinned to a commit (the h2o pattern: fetch upstream at a fixed
# SHA and build it here, tuned for this CPU). No liburing: libioma issues the io_uring syscalls
# directly. Only the baseline handler lives in this entry.
ARG LIBIOMA_VERSION=42b5d1d8636aee00f3809aff2cfbe4d41195ec89
RUN mkdir -p /tmp/libioma && \
    curl -LSs "https://github.com/MDA2AV/libioma/archive/${LIBIOMA_VERSION}.tar.gz" \
      | tar --strip-components=1 -xz -C /tmp/libioma
COPY main.c .

# Phase 1: an instrumented build of the library and the handler (LTO on, profile counters in).
RUN make -C /tmp/libioma libioma.a CFLAGS="-O3 -march=native -flto -fprofile-generate -fprofile-update=atomic" && \
    gcc -O3 -march=native -flto -fprofile-generate -fprofile-update=atomic -std=gnu11 -pthread \
        -I/tmp/libioma/include -c main.c -o main.o && \
    gcc -O3 -march=native -flto -fprofile-generate -pthread main.o /tmp/libioma/libioma.a -o server-train -pthread

# Phase 2: train it on the baseline's request shapes - keep-alive GETs, Content-Length and chunked
# POSTs, connection churn - then stop it cleanly so it writes the .gcda files next to the objects.
RUN ./server-train 4 & sleep 1 && \
    ab -k -c 64 -n 300000 'http://127.0.0.1:8080/baseline11?a=1&b=2' >/dev/null 2>&1 && \
    for i in $(seq 200); do \
        curl -s -d 20 'http://127.0.0.1:8080/baseline11?a=1&b=2' >/dev/null && \
        curl -s -H 'Transfer-Encoding: chunked' --data-binary 20 'http://127.0.0.1:8080/baseline11?a=1' >/dev/null; \
    done && \
    ab -c 32 -n 5000 'http://127.0.0.1:8080/baseline11?a=1&b=2' >/dev/null 2>&1 && \
    pkill -INT -x server-train && sleep 1 && \
    test -n "$(ls /tmp/libioma/obj/*.gcda)" && ls /tmp/libioma/obj/*.gcda | wc -l

# Phase 3: rebuild with the profiles (objects removed, .gcda kept, same paths so they match).
RUN rm -f /tmp/libioma/obj/*.o main.o server-train && \
    make -C /tmp/libioma libioma.a CFLAGS="-O3 -march=native -flto -ffat-lto-objects -fprofile-use -fprofile-correction" && \
    gcc -O3 -march=native -flto -fprofile-use -fprofile-correction -std=gnu11 -pthread \
        -I/tmp/libioma/include -c main.c -o main.o && \
    gcc -O3 -march=native -flto -fprofile-use -pthread main.o /tmp/libioma/libioma.a -o server -pthread

FROM ubuntu:24.04
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
