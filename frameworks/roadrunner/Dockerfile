FROM erlang:29.0-alpine AS build
RUN apk add --no-cache ca-certificates curl git
WORKDIR /src
# Unreleased roadrunner and its Protocol Buffers adapter, fetched as source
# archives at fixed commits into _checkouts (rebar3 uses them in place of
# the git deps), with the version pinned since an archive has no git tags.
ARG RR_SHA=d3f018ed8a9610f473dbe6519ddde36815611217
ARG RR_PROTOBUF_SHA=13a22a68adf6d185a2f675bf164b448173f62a1a
RUN set -eux; mkdir -p _checkouts; \
    fetch() { \
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://codeload.github.com/arizona-framework/$1/tar.gz/$2" | tar -xz -C _checkouts; \
      mv "_checkouts/$1-$2" "_checkouts/$1"; \
      sed -i "s/{vsn, semver}/{vsn, \"$3\"}/" "_checkouts/$1/src/$1.app.src"; \
      grep -q "{vsn, \"$3\"}" "_checkouts/$1/src/$1.app.src"; \
    }; \
    fetch roadrunner "$RR_SHA" "0.16.2+main.${RR_SHA%"${RR_SHA#???????}"}"; \
    fetch roadrunner_grpc_protobuf "$RR_PROTOBUF_SHA" "0.0.0+main.${RR_PROTOBUF_SHA%"${RR_PROTOBUF_SHA#???????}"}"
COPY rebar.config rebar.lock ./
COPY config ./config
COPY proto ./proto
COPY src ./src
RUN rebar3 as prod release

FROM alpine:3.23
RUN apk add --no-cache libstdc++ ncurses-libs openssl
COPY --from=build /src/_build/prod/rel/roadrunner_httparena /app
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
CMD ["/app/bin/roadrunner_httparena", "foreground"]
