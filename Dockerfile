# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS downloader

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/install-cli-api-proxy.sh /usr/local/bin/install-cli-api-proxy

ARG CLI_PROXY_VERSION=7.2.121
ARG TARGETARCH
RUN /usr/local/bin/install-cli-api-proxy \
    "${CLI_PROXY_VERSION}" "${TARGETARCH}" /out/cli-proxy-api

FROM debian:bookworm-slim

ARG CLI_PROXY_VERSION=7.2.121
LABEL org.opencontainers.image.title="CLIProxyAPI" \
      org.opencontainers.image.description="Container image for router-for-me/CLIProxyAPI" \
      org.opencontainers.image.source="https://github.com/router-for-me/CLIProxyAPI" \
      org.opencontainers.image.version="${CLI_PROXY_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends busybox-static ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 cliproxy \
    && useradd --uid 10001 --gid cliproxy --home-dir /data --no-create-home --shell /usr/sbin/nologin cliproxy \
    && install -d -o cliproxy -g cliproxy /config /data

COPY --from=downloader /out/cli-proxy-api /usr/local/bin/cli-proxy-api

USER cliproxy
WORKDIR /data

ENV HOME=/data \
    WRITABLE_PATH=/data \
    TZ=UTC

EXPOSE 8317 8085 1455 54545 51121 11451

ENTRYPOINT ["/usr/local/bin/cli-proxy-api"]
CMD ["--config", "/config/config.yaml"]
