FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev
COPY server.js .
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "server.js"]
