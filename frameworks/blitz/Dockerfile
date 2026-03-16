FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y wget xz-utils ca-certificates libsqlite3-dev && \
    wget -q https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz && \
    tar xf zig-linux-x86_64-0.14.0.tar.xz && \
    mv zig-linux-x86_64-0.14.0 /usr/local/zig
ENV PATH="/usr/local/zig:$PATH"
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src ./src
RUN zig build -Doptimize=ReleaseFast

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/zig-out/bin/blitz /server
ENV BLITZ_URING=1
EXPOSE 8080
CMD ["/server"]
