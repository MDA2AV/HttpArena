FROM oven/bun:latest
WORKDIR /app
COPY server.ts entrypoint.sh ./
RUN chmod +x entrypoint.sh
EXPOSE 8080 8443
CMD ["/app/entrypoint.sh"]
