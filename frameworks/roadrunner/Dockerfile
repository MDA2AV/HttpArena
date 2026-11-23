FROM erlang:29.0-alpine AS build
RUN apk add --no-cache ca-certificates curl git
WORKDIR /src
# Unreleased roadrunner and its Protocol Buffers adapter, fetched as source
# archives at fixed commits into _checkouts (rebar3 uses them in place of
# the git deps), with the version pinned since an archive has no git tags.
ARG RR_SHA=4882776741f5da54084b21ce227070ff5d934641
ARG RR_PROTOBUF_SHA=13a22a68adf6d185a2f675bf164b448173f62a1a
# One curl call for both archives: the second reuses the first's connection
# and DNS answer (the bench host's resolver has failed a second lookup).
RUN set -eux; mkdir -p _checkouts; cd _checkouts; \
    curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 \
      -o rr.tgz "https://codeload.github.com/arizona-framework/roadrunner/tar.gz/$RR_SHA" \
      -o pb.tgz "https://codeload.github.com/arizona-framework/roadrunner_grpc_protobuf/tar.gz/$RR_PROTOBUF_SHA"; \
    tar -xzf rr.tgz; tar -xzf pb.tgz; rm rr.tgz pb.tgz; \
    mv "roadrunner-$RR_SHA" roadrunner; \
    mv "roadrunner_grpc_protobuf-$RR_PROTOBUF_SHA" roadrunner_grpc_protobuf; \
    RV="0.16.2+main.${RR_SHA%"${RR_SHA#???????}"}"; \
    PV="0.0.0+main.${RR_PROTOBUF_SHA%"${RR_PROTOBUF_SHA#???????}"}"; \
    sed -i "s/{vsn, semver}/{vsn, \"$RV\"}/" roadrunner/src/roadrunner.app.src; \
    sed -i "s/{vsn, semver}/{vsn, \"$PV\"}/" roadrunner_grpc_protobuf/src/roadrunner_grpc_protobuf.app.src; \
    grep -q "{vsn, \"$RV\"}" roadrunner/src/roadrunner.app.src; \
    grep -q "{vsn, \"$PV\"}" roadrunner_grpc_protobuf/src/roadrunner_grpc_protobuf.app.src
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
