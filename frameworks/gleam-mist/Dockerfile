FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang-alpine AS build
RUN apk add --no-cache gcc musl-dev sqlite-dev
WORKDIR /app
COPY gleam.toml .
RUN gleam deps download
COPY src ./src
RUN gleam export erlang-shipment

FROM erlang:28-alpine
RUN apk add --no-cache sqlite-libs
WORKDIR /app
COPY --from=build /app/build/erlang-shipment /app
EXPOSE 8080
CMD ["/app/entrypoint.sh", "run"]
