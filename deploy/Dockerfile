# Gateway image. Build from the repository root: docker build -f deploy/Dockerfile .
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN apk add --no-cache build-base && CGO_ENABLED=1 go build -trimpath -ldflags="-s -w" -o /gateway ./cmd/gateway

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /gateway /gateway
EXPOSE 8080 9090
ENTRYPOINT ["/gateway"]
