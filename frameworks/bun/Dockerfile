FROM oven/bun:1.4
WORKDIR /app
COPY server.ts entrypoint.sh ./
RUN chmod +x entrypoint.sh
EXPOSE 8080
CMD ["./entrypoint.sh"]
