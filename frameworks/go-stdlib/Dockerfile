FROM golang:1.26-alpine AS build
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o server main.go

FROM scratch
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
