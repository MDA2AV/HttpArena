FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    sbcl curl ca-certificates build-essential \
    libev-dev libsqlite3-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Quicklisp
RUN curl -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
    && sbcl --non-interactive \
       --load /tmp/quicklisp.lisp \
       --eval '(quicklisp-quickstart:install)' \
       --eval '(ql:add-to-init-file)'

# Pre-fetch dependencies so layer is cached
RUN sbcl --non-interactive \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :cl-sqlite) :silent t)'

COPY src/ /app/src/

# Build standalone binary
RUN sbcl --non-interactive --load /app/src/build.lisp

# ------- runtime image -------
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libev4 libsqlite3-0 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/woo-server /woo-server
EXPOSE 8080
CMD ["/woo-server"]
