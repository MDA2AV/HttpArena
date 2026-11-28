FROM node:26-trixie-slim AS build

# git: uWebSockets.js is published from its GitHub repository, not from the npm registry
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --no-audit --no-fund

FROM node:26-trixie-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY package.json server.ts ./
COPY views ./views

ENV NODE_ENV=production
EXPOSE 8080 8081
CMD ["node", "server.ts"]
