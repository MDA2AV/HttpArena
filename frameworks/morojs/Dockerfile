FROM node:26-trixie-slim AS build
WORKDIR /app
COPY package.json .
# @morojs/engine ships prebuilt binaries, so no toolchain is needed here
RUN npm install --omit=dev --no-audit --no-fund

FROM node:26-trixie-slim
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY app.mjs .
COPY views ./views
ENV NODE_ENV=production
# One libuv threadpool serves every worker thread in the process. Little rides
# on it now - compression runs inline on the worker and static files are
# served from the middleware's memory cache, which stats the disk once a
# second at most - but what does (the cache's revalidation, the first read of
# each file, DNS) should not queue behind Node's default of four threads. Moro
# sizes the pool to 64 itself, but only at listen(), after its startup has
# already initialised it; an environment variable at process start is what
# Node reads. 64 matches the benchmark cpuset.
ENV UV_THREADPOOL_SIZE=64
EXPOSE 8080
CMD ["node", "app.mjs"]
