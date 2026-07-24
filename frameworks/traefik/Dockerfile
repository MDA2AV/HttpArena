FROM traefik:v3.1

# Traefik's local-plugin loader expects sources at
#   /plugins-local/src/<import-path>/
# where <import-path> matches the `moduleName` declared under
# experimental.localPlugins.<name> in the static config. Our plugin's
# import path is github.com/httparena/traefik-httparena, so the Go files
# go in /plugins-local/src/github.com/httparena/traefik-httparena/.
COPY plugin/httparena/ /plugins-local/src/github.com/httparena/traefik-httparena/

# Static + dynamic Traefik config.
COPY traefik.yml  /etc/traefik/traefik.yml
COPY dynamic.yml  /etc/traefik/dynamic.yml

EXPOSE 8080

# The traefik image already has an entrypoint that reads --configFile; we
# point at our static config. No CMD override on the binary itself.
CMD ["--configFile=/etc/traefik/traefik.yml"]
