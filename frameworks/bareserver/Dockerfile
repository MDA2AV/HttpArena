FROM node:26-trixie-slim AS build
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git python3 make g++ libpq-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --no-audit --no-fund

FROM node:26-trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl libpq5 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY app.js .
ENV NODE_ENV=production
ENV UV_THREADPOOL_SIZE=64
EXPOSE 8080
CMD ["node", "app.js"]
