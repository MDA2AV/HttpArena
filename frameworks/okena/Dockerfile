# okena with HttpArena's handler module (httparena.inc) assembled in, the way
# nginx takes a module at build time: one static binary, no libc.
FROM debian:trixie-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git make \
 && rm -rf /var/lib/apt/lists/*
ARG OKENA_REPO=https://github.com/Lu4nScr1pt1ng/okena
ARG OKENA_COMMIT=4741c5c87f7e8a57d4a59ac2c8bed97a582b3461
WORKDIR /src
RUN git init -q okena \
 && git -C okena fetch -q --depth 1 "$OKENA_REPO" "$OKENA_COMMIT" \
 && git -C okena checkout -q FETCH_HEAD
COPY httparena.inc /src/httparena.inc
RUN make -C okena MODULES=/src/httparena.inc

FROM scratch
COPY --from=build /src/okena/build/okena /okena
COPY okena.conf /etc/okena/okena.conf
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
ENTRYPOINT ["/okena", "-c", "/etc/okena/okena.conf"]
