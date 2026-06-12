# BlackBull-on-HttpArena container.
#
# Build context = bench/httparena/ (this directory).  BlackBull is
# installed from PyPI, so the host source tree is not needed at build
# time.  Build with:
#
#   docker build -t blackbull-httparena bench/httparena/
#
# Run with HttpArena-shaped mounts (cleartext HTTP/1.1 on :8080, h2c
# on :8082, TLS HTTP/1.1 on :8081, TLS HTTP/2 on :8443):
#
#   docker run --rm --network host \
#     -v $PWD/bench/httparena/_local/data:/data:ro \
#     -v $PWD/bench/httparena/_local/certs:/certs:ro \
#     blackbull-httparena

FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install BlackBull from PyPI — same install path real users follow.
# Pins live in requirements.txt; bump in lockstep with each release.
# The [compression] extra pulls brotli + zstandard for the json-comp
# profile.  --no-cache-dir keeps the pip cache out of the image layer.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy framework files last so app/launcher edits don't bust the
# slow pip layer.
COPY app.py launcher.py ./

EXPOSE 8080 8081 8082 8443

CMD ["python", "launcher.py"]
