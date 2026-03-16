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

# Pre-fetch + compile all deps
RUN sbcl --non-interactive \
    --eval '(ql:quickload (list :woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)'

COPY src/ /app/src/

# Build standalone executable via save-lisp-and-die
# Single stage so CFFI foreign library paths match exactly at runtime
RUN sbcl --non-interactive --load /app/src/build.lisp

EXPOSE 8080

CMD ["/app/woo-server"]
