FROM node:26-trixie-slim

WORKDIR /app

# The only dependencies are the two drivers the database profiles cannot run
# without: node ships neither a Postgres nor a Redis client. Copied before the
# server so a source edit does not re-run the install.
COPY package.json .
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js .

ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "server.js"]
