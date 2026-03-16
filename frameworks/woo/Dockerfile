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
    && echo ';;; Load Quicklisp on startup' >> /root/.sbclrc \
    && echo '#-quicklisp' >> /root/.sbclrc \
    && echo '(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))' >> /root/.sbclrc \
    && echo '  (when (probe-file quicklisp-init) (load quicklisp-init)))' >> /root/.sbclrc

# Pre-fetch + compile all Quicklisp deps (FASLs cached in image layer)
RUN sbcl --non-interactive \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)'

COPY src/server.lisp /app/src/server.lisp

EXPOSE 8080

# Load pre-compiled deps (fast — FASLs are cached) and start server directly.
# No save-lisp-and-die: avoids CFFI foreign library reload issues with libev.
CMD ["sbcl", "--non-interactive", \
     "--eval", "(ql:quickload '(:woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)", \
     "--load", "/app/src/server.lisp", \
     "--eval", "(httparena::main)"]
