FROM elixir:1.20-otp-29-slim AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.rebar --force && mix local.hex --force

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
RUN mix compile && mix release

FROM elixir:1.20-otp-29-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/_build/prod/rel/httparena ./

EXPOSE 8080
CMD ["/app/bin/httparena", "start"]
