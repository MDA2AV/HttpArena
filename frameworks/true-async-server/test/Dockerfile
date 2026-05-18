FROM python:3.12-slim

# curl with HTTP/2 support (Debian bookworm libcurl includes nghttp2)
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl \
    && rm -rf /var/lib/apt/lists/*

COPY validate.sh /validate.sh
RUN chmod +x /validate.sh

ENTRYPOINT ["/validate.sh"]
