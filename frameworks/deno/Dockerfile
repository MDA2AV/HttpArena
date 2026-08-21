FROM denoland/deno:2.9.5
WORKDIR /app
COPY server.ts .
RUN deno cache server.ts
EXPOSE 8080
# --parallel is Deno's own multi-core scaling: one process per core, all
# binding 8080 with SO_REUSEPORT. --allow-read for the dataset, --allow-net to
# bind, --allow-env for DATASET_PATH.
# --unstable-net is what lets the TLS listener on 8081 use reusePort. Deno has it
# stable for plain TCP but not yet for Deno.listenTls, and without it a single
# worker would own the TLS port while the other N-1 sat idle on the two TLS
# profiles. Everything else here is the runtime's stable surface.
CMD ["deno", "serve", "--parallel", "--port", "8080", "--host", "0.0.0.0", \
     "--allow-read", "--allow-net", "--allow-env", "--allow-sys", \
     "--unstable-net", "server.ts"]
