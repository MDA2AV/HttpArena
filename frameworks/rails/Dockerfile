FROM ruby:4.0-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libsqlite3-dev libpq-dev libyaml-dev libjemalloc2 libpq5 && \
    rm -rf /var/lib/apt/lists/*

# Use Jemalloc
ENV LD_PRELOAD=libjemalloc.so.2

ENV RUBY_YJIT_ENABLE=1
ENV RUBY_MN_THREADS=1
ENV RACK_ENV=production
ENV WEB_CONCURRENCY=auto
ENV RAILS_MAX_THREADS=3

WORKDIR /app

COPY Gemfile .
RUN bundle install --jobs=$(nproc)

COPY . .

EXPOSE 8080 8081

ENV THRUSTER_TARGET_PORT=8080
ENV THRUSTER_LOG_REQUESTS=false

CMD ["thrust", "bin/rails", "s"]
