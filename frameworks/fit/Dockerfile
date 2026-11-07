FROM golang:1.27.3-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
COPY httparena ./httparena
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o fit .

FROM scratch
COPY --from=build /app/fit /fit
COPY fit.conf /etc/fit/fit.conf
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
CMD ["/fit", "run", "-c", "/etc/fit/fit.conf"]
