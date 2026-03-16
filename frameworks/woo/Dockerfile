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

# Pre-load all deps
RUN sbcl --non-interactive \
    --load '/root/quicklisp/setup.lisp' \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)'

COPY src/ /app/src/

# Build standalone executable via save-lisp-and-die.
# Single-stage build: foreign library paths match between build and runtime.
# startup.lisp calls cffi:reload-foreign-libraries before main to restore
# CFFI handles that become stale after core image save/restore.
RUN sbcl --non-interactive \
    --load '/root/quicklisp/setup.lisp' \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)' \
    --load '/app/src/server.lisp' \
    --load '/app/src/startup.lisp' \
    --eval '(sb-ext:save-lisp-and-die "/app/woo-server" \
              :toplevel (function httparena-startup::toplevel) \
              :executable t \
              :purify t)'

EXPOSE 8080

CMD ["/app/woo-server"]
