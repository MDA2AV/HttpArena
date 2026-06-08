FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates curl unzip build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V 0.5.1 (prebuilt release binary).
RUN curl -fsSL https://github.com/vlang/v/releases/download/0.5.1/v_linux.zip -o /tmp/v.zip && \
    unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip && \
    ln -s /opt/v/v /usr/local/bin/v

WORKDIR /app
COPY . .
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
