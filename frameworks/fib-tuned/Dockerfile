FROM golang:1.27-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
COPY proto ./proto
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o server .

FROM scratch
COPY --from=build /app/server /server
# Requests make garbage far faster than the server keeps anything live, so a
# higher GOGC trades memory for the collector's share of the CPUs. Each prefork
# child has a heap of its own, and on 64 CPUs, against GOGC=100 and 400,
# GOGC=200 served json-tls at 1.56M req/s (1.42M, 1.64M) in 688 MB (511 MB,
# 1.0 GB), json-comp over 16384 connections at 586k (559k, 600k) in 2.5 GB
# (0.9 GB, 6.7 GB), and baseline and limited-conn alike at about half 400's
# memory.
ENV GOGC=200
EXPOSE 8080 8081 8082 8443/tcp 8443/udp 9000
CMD ["/server"]
