FROM swift:6.2-jammy AS build
RUN apt-get update && \
    apt-get install -y --no-install-recommends libssl-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Package.swift .
COPY Sources ./Sources
RUN swift build -c release

FROM ubuntu:22.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libcurl4 libxml2 zlib1g && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/swift/linux/lib*.so /usr/lib/swift/linux/
COPY --from=build /app/.build/release/server /server
EXPOSE 8080
CMD ["/server"]
