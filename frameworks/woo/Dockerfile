FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    sbcl curl ca-certificates build-essential \
    libev-dev libsqlite3-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Quicklisp
RUN curl -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
    && sbcl --non-interactive \
       --load /tmp/quicklisp.lisp \
       --eval '(quicklisp-quickstart:install)' \
    && rm /tmp/quicklisp.lisp

# Pre-compile all deps into FASLs
RUN sbcl --non-interactive \
    --load '/root/quicklisp/setup.lisp' \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)'

COPY src/ /app/src/

# No save-lisp-and-die: CFFI foreign library handles become stale in core
# images and cffi:reload-foreign-libraries is unreliable with libev.
# Instead, load from pre-compiled FASLs at startup (~2-3s with warm cache).

EXPOSE 8080

CMD ["sbcl", "--noinform", "--disable-debugger", \
     "--load", "/root/quicklisp/setup.lisp", \
     "--eval", "(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)", \
     "--load", "/app/src/server.lisp", \
     "--eval", "(httparena::main)"]
