FROM erlang:29.0-alpine AS build
RUN apk add --no-cache ca-certificates git
WORKDIR /src
COPY rebar.config ./
COPY config ./config
COPY src ./src
RUN rebar3 as prod release

FROM alpine:3.23
RUN apk add --no-cache libstdc++ ncurses-libs openssl
COPY --from=build /src/_build/prod/rel/roadrunner_httparena /app
EXPOSE 8080 8081 8082 8443
CMD ["/app/bin/roadrunner_httparena", "foreground"]
