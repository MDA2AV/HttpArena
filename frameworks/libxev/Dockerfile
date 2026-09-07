FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Zig 0.16.0 - libxev's minimum supported version (a stable release, not a nightly).
RUN curl -LSs https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
      | tar -xJ -C /opt \
    && ln -s /opt/zig-x86_64-linux-0.16.0/zig /usr/local/bin/zig

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY third_party/ third_party/

# Fetches libxev (pinned by url+hash in build.zig.zon) and builds the server tuned for this CPU.
RUN zig build -Doptimize=ReleaseFast -Dcpu=native

FROM ubuntu:24.04
COPY --from=build /app/zig-out/bin/server /server
EXPOSE 8080
CMD ["/server"]
