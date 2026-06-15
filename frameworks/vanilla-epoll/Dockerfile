FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates curl unzip build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V 0.5.1 (prebuilt release binary — no source build, and it
# avoids the `git checkout <tag> && make` vc-mismatch problem).
RUN curl -fsSL https://github.com/vlang/v/releases/download/0.5.1/v_linux.zip -o /tmp/v.zip && \
    unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip && \
    ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server).
RUN git clone --depth 1 https://github.com/enghitalo/vanilla /root/.vmodules/vanilla

WORKDIR /app
COPY . .
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]
