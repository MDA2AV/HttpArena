FROM node:26-trixie-slim AS build
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:26-trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
# package.json rides along for "type": "module"; node 26 strips the types off
# server.ts on load, so there is no build step
COPY package.json server.ts ./
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "server.ts"]
