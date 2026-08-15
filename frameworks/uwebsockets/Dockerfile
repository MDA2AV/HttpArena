FROM node:24-trixie-slim AS build
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:24-trixie-slim
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY app.js .
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "app.js"]
