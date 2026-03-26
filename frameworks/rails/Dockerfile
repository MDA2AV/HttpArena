FROM ruby:3.4-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libsqlite3-dev libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

ENV RUBY_YJIT_ENABLE=1
ENV RACK_ENV=production
ENV WEB_CONCURRENCY=auto

WORKDIR /app

COPY Gemfile .
RUN bundle install --jobs=$(nproc)

COPY . .

EXPOSE 8080

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
