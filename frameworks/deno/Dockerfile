FROM denoland/deno:2.9.5
WORKDIR /app
COPY server.ts .
RUN deno cache server.ts
EXPOSE 8080
# --parallel is Deno's own multi-core scaling: one process per core, all
# binding 8080 with SO_REUSEPORT. --allow-read for the dataset, --allow-net to
# bind, --allow-env for DATASET_PATH.
CMD ["deno", "serve", "--parallel", "--port", "8080", "--host", "0.0.0.0", \
     "--allow-read", "--allow-net", "--allow-env", "server.ts"]
