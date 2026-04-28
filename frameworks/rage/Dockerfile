FROM ruby:4.0-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libyaml-dev libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

# Use Jemalloc
ENV LD_PRELOAD=libjemalloc.so.2

ENV RUBY_YJIT_ENABLE=1
ENV RAGE_ENV=production

WORKDIR /app

COPY Gemfile* .
RUN bundle config set deployment 'true'
RUN bundle install --jobs=$(nproc)

COPY . .

EXPOSE 8080

CMD ["bundle", "exec", "rage", "server", "-p", "8080", "-b", "0.0.0.0"]
