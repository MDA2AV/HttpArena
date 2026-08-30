FROM drogonframework/drogon:latest AS build
WORKDIR /app
COPY CMakeLists.txt main.cc ./
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j$(nproc)

FROM drogonframework/drogon:latest

# jsoncpp allocates a node per JSON value, so a /json response is hundreds of
# small allocations, and with one worker per core they all contend on the same
# glibc arena. Measured here (server on 16 cores, load on the other 16):
#
#   /json              152.1 -> 118 us/req   +29% rps
#   /json + gzip       253.6 -> 155.0        +63% rps
#   /json over TLS     160.6 -> 122.0        +32% rps
#
# Same pattern the Ruby entries already use (rails, sinatra, roda, hanami,
# rack-iodine, rack-falcon, rage) and the allocator that vinyl-cache links.
# It changes no serialization: the bytes on the wire are byte-identical.
RUN apt-get update && apt-get install -y --no-install-recommends libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*
ENV LD_PRELOAD=libjemalloc.so.2

COPY --from=build /app/build/server /server
EXPOSE 8080
CMD ["/server"]
