FROM golang:1.27.1-alpine3.24 AS builder

# Stamped into internal/glance.buildVersion; CI passes the git tag or sha-<short>.
ARG VERSION=dev

WORKDIR /app
COPY . /app
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X github.com/glanceapp/glance/internal/glance.buildVersion=${VERSION}" .

FROM alpine:3.24.1

WORKDIR /app
COPY --from=builder /app/glance .

EXPOSE 8080/tcp
ENTRYPOINT ["/app/glance", "--config", "/app/config/glance.yml"]
