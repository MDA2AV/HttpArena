FROM node:24-trixie-slim AS build
# python3/make/g++/libpq-dev build pg-native, the libpq bindings the app prefers at runtime
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git python3 make g++ libpq-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:24-trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libpq5 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY app.js .
ENV NODE_ENV=production
EXPOSE 8080 8081
CMD ["node", "app.js"]
