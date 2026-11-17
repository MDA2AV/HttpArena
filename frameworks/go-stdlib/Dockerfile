FROM golang:1.27.3-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o server main.go

FROM scratch
COPY --from=build /app/server /server
EXPOSE 8080 8081 8082 8443
CMD ["/server"]
