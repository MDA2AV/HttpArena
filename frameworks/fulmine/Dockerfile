FROM node:26-trixie-slim AS build
# python3/make/g++/libpq-dev build pg-native, the libpq bindings the app prefers at runtime
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git python3 make g++ libpq-dev && \
    rm -rf /var/lib/apt/lists/*
RUN git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:26-trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl libpq5 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY app.js .
COPY views ./views
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "app.js"]
