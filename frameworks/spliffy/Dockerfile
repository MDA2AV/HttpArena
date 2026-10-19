FROM node:26-trixie-slim AS build
# git: spliffy depends on uWebSockets.js straight from its GitHub repo, not from the registry
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git && \
    rm -rf /var/lib/apt/lists/*
RUN git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:26-trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY package.json app.mjs ./
COPY lib ./lib
COPY www ./www
COPY views ./views
# the static files are mounted at runtime, the route tree reaches them through this link
RUN ln -s /data/static /app/www/static
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "app.mjs"]
