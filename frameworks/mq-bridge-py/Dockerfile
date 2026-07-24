# HttpArena image for the mq-bridge-py (Python) entry.
#
# Installs the prebuilt mq_bridge_py wheel from PyPI and runs server.py on port
# 8080. The wheel is abi3 (cp38+) manylinux2014, so it works on this base image
# without compiling from source. Pin MQB_VERSION to a released version.
FROM python:3.12-slim

ARG MQB_VERSION=0.2.21

RUN groupadd --system appuser \
    && useradd --system --gid appuser --create-home --home-dir /home/appuser --shell /usr/sbin/nologin appuser \
    && mkdir -p /app \
    && chown -R appuser:appuser /app
# psycopg[binary] powers the optional /async-db profile; absent DATABASE_URL it is unused.
RUN pip install --no-cache-dir "mq-bridge-py==${MQB_VERSION}" "psycopg[binary]>=3.1" "psycopg_pool>=3.2"
WORKDIR /app
COPY --chown=appuser:appuser server.py /app/server.py
EXPOSE 8080
# Take CPython's cyclic GC off the request hot path: the JSON handlers allocate
# many short-lived dicts/lists per request (no reference cycles), so disabling
# the periodic collector removes its scan overhead with no leak. `count` is the
# safe alternative if a handler ever introduces cycles.
ENV MQ_BRIDGE_PY_GC_MODE=off
# Scale Python across cores with one process per core (single GIL each),
# co-binding port 8080 via SO_REUSEPORT. Unset/0 => all cores; set 1 to disable.
ENV MQB_WORKERS=0
USER appuser:appuser
CMD ["python", "server.py"]
