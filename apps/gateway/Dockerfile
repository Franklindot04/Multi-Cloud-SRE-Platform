# syntax=docker/dockerfile:1

# Build stage: pinned toolchain. Base image digests are pinned in a later change (see apps/README.md).
FROM golang:1.27.3-alpine3.23 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/gateway ./cmd/gateway

# Final stage: distroless static image. It has no shell or package manager, runs as the non-root
# user 65532 and works with a read-only root filesystem because the service writes nothing to disk.
# There is no HEALTHCHECK: the image has no tools to run one, and Kubernetes uses /healthz and /readyz.
FROM gcr.io/distroless/static-debian13:nonroot
ARG VERSION=dev
ARG COMMIT=unknown
ENV APP_VERSION=$VERSION APP_COMMIT=$COMMIT
COPY --from=build /out/gateway /gateway
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/gateway"]
