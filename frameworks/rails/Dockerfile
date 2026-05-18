FROM ruby:4.0-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev libjemalloc2 libpq5 && \
    rm -rf /var/lib/apt/lists/*

# Use Jemalloc
ENV LD_PRELOAD=libjemalloc.so.2

# YJIT is enabled by Rails
# ENV RUBY_YJIT_ENABLE=1
ENV RUBY_MN_THREADS=1
ENV RACK_ENV=production
ENV WEB_CONCURRENCY=auto
ENV RAILS_MAX_THREADS=3
ENV MAX_IO_THREADS=5

WORKDIR /app

COPY Gemfile* .
RUN bundle config set deployment 'true'
RUN bundle install --jobs=$(nproc)

COPY . .

EXPOSE 8080 8081

CMD ["bin/rails", "server"]
