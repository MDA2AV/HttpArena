FROM ruby:4.0-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libpq-dev libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

# Use Jemalloc
ENV LD_PRELOAD=libjemalloc.so.2

ENV RUBY_YJIT_ENABLE=1
ENV RUBY_MN_THREADS=1
ENV RACK_ENV=production
ENV WEB_CONCURRENCY=auto
ENV MAX_THREADS=4
ENV MAX_IO_THREADS=10

WORKDIR /app

COPY Gemfile* .
RUN bundle config set deployment 'true'
RUN bundle install --jobs=$(nproc)

COPY . .

EXPOSE 8080 8081

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
