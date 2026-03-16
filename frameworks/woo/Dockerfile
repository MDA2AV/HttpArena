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

# Build standalone executable using save-lisp-and-die.
# Key: single-stage build so CFFI dlopen paths match at runtime.
# No :compression — compressed cores take >30s to decompress on CI.
# cffi:reload-foreign-libraries re-opens all foreign lib handles on startup.
RUN sbcl --non-interactive \
    --load '/root/quicklisp/setup.lisp' \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)' \
    --load '/app/src/server.lisp' \
    --eval '(defun woo-toplevel () (cffi:reload-foreign-libraries) (httparena::main))' \
    --eval '(sb-ext:save-lisp-and-die "/app/woo-server" :toplevel (function woo-toplevel) :executable t)'

EXPOSE 8080

CMD ["/app/woo-server"]
