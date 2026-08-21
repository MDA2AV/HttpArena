FROM node:26-trixie-slim AS build
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:26-trixie-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY package.json .
COPY app.js .
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "app.js"]
