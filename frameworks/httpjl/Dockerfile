FROM julia:1.11.6-bookworm AS build
ENV JULIA_DEPOT_PATH=/depot
WORKDIR /app
COPY Project.toml Manifest.toml ./
COPY src ./src
COPY app.jl start.sh ./
# Manifest.toml pins the whole tree; `using` writes the package images, which
# hold native code for the request path so the first request does not compile it
RUN julia --project=/app --startup-file=no -e 'using Pkg; Pkg.instantiate()' \
    && julia --project=/app --startup-file=no -e 'using ArenaHttpJl' \
    && chmod +x /app/start.sh \
    && rm -rf /depot/registries /depot/scratchspaces /depot/logs

FROM julia:1.11.6-bookworm
ENV JULIA_DEPOT_PATH=/depot
WORKDIR /app
COPY --from=build /depot /depot
COPY --from=build /app /app
EXPOSE 8080
CMD ["/app/start.sh"]
