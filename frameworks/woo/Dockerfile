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

# Pre-fetch + compile all Quicklisp deps (FASLs get cached)
RUN sbcl --non-interactive \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)'

COPY src/server.lisp /app/src/server.lisp

# Pre-compile server.lisp to FASL
RUN sbcl --non-interactive \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)' \
    --eval '(compile-file "/app/src/server.lisp" :output-file "/app/src/server.fasl")'

EXPOSE 8080

# Load pre-compiled FASLs at runtime — avoids CFFI/save-lisp-and-die issues.
# All FASLs are already compiled, so quickload just loads them (no compilation).
CMD ["sbcl", "--non-interactive", \
     "--eval", "(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)", \
     "--load", "/app/src/server.fasl", \
     "--eval", "(httparena::main)"]
