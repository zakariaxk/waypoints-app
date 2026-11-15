# Gateway image. Build from the repository root: docker build -f deploy/Dockerfile .
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN apk add --no-cache build-base && CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /gateway ./cmd/gateway

FROM alpine:3.20
RUN apk add --no-cache ca-certificates \
 && adduser -D -u 10001 gateway
COPY --from=build /gateway /gateway
# The metrics/pprof listener binds 127.0.0.1 inside the container and is not
# published; only the public API port is exposed.
USER gateway
EXPOSE 8080
ENTRYPOINT ["/gateway"]
