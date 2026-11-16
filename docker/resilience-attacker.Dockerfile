# Builds the resilience Go attack client to a static binary.
#
# This is only the FALLBACK path: when the bench host has a native `go`,
# resilience.sh builds the client directly with `go build`. When it doesn't,
# resilience.sh builds this image, extracts /attacker, and runs the binary ON
# THE HOST (not inside a container) — the floods need the host's full ephemeral
# port range and the host-pinned CPU set, so the client never runs containerised.
#
# Build context is scripts/resilience/attacker/ (the Go source).
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /attacker .

FROM scratch
COPY --from=build /attacker /attacker
ENTRYPOINT ["/attacker"]
