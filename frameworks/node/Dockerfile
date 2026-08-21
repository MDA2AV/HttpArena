# No dependencies, so no build stage: the entry is one file on the node image.
FROM node:26-trixie-slim
WORKDIR /app
COPY server.js .
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "server.js"]
