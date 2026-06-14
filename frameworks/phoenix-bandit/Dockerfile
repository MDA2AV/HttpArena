
FROM elixir:1.20-otp-29-slim AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.rebar --force && \
    mix local.hex --force

WORKDIR /app

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY lib lib

RUN mix compile

COPY config/runtime.exs config/

RUN mix release



FROM elixir:1.20-otp-29-slim AS final

RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/phoenix_bandit ./

USER nobody

EXPOSE 8080

CMD ["/app/bin/phoenix_bandit", "start"]