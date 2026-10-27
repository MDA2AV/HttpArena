FROM ruby:4.0.9-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential curl ca-certificates clang libclang-dev pkg-config libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal

# Use Jemalloc
ENV LD_PRELOAD=libjemalloc.so.2

ENV RUBY_YJIT_ENABLE=1
ENV RACK_ENV=production

WORKDIR /app

COPY Gemfile* .
RUN bundle config set deployment 'true'
RUN bundle install --jobs=$(nproc)

COPY . .

EXPOSE 8080

CMD ["bundle", "exec", "kino"]
