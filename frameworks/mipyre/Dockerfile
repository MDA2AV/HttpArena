# mipyre from PyPI: a cp314 manylinux x86_64 wheel, so no Rust toolchain in the
# image and nothing compiled with -C target-cpu=native. pip also looks in
# wheels/ next to this file, so a local build can be checked before its
# release: --build-arg MIPYRE_VERSION=<its version>.
FROM python:3.14-slim
WORKDIR /app

ARG MIPYRE_VERSION=3.0.0
COPY . ./
RUN pip install --no-cache-dir --find-links ./wheels "mipyre==${MIPYRE_VERSION}"

# Arena harness expectations:
#   - 8080 plaintext HTTP/1.1
#   - 8081 HTTPS HTTP/1.1 (json-tls, static-tls, 8gbit)
#   - 8082 plaintext HTTP/1.1 + h2c prior knowledge (baseline-h2c, json-h2c)
#   - 8443 HTTPS HTTP/2 (baseline-h2, static-h2)
#   - /certs/server.{crt,key}  mounted by harness
#   - /data/dataset.json       mounted by harness
#   - /data/static             mounted by harness
#   - $DATABASE_URL            set by harness when PG profile active
EXPOSE 8080 8081 8082 8443
CMD ["python3", "launcher.py"]
