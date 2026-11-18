FROM node:26-trixie-slim AS build
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

FROM node:26-trixie-slim
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY app.js .
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "app.js"]
