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
# The libuv threadpool carries the compression and file reads of every worker
# thread in the process. Moro sizes it to 64 itself, but only at listen(),
# after its startup has already initialised the pool at Node's default of 4;
# an environment variable at process start is what Node reads. 64 matches the
# benchmark cpuset.
ENV UV_THREADPOOL_SIZE=64
EXPOSE 8080
CMD ["node", "app.mjs"]
