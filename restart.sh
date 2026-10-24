#!/bin/sh
# Restart the CLIProxyAPI container and wait until it is healthy.
# Exit 0: restarted, or nothing to restart. Exit 1: it did not become healthy.
set -eu

cd -- "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is unavailable. The container was not restarted."
  exit 0
fi

container_id=$(docker compose ps -q cli-api-proxy 2>/dev/null || true)
if [ -z "$container_id" ] || [ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" != true ]; then
  echo "CLIProxyAPI is not running. Start it with: docker compose up -d"
  exit 0
fi

docker compose restart cli-api-proxy

# Wait for the healthcheck. Containers without one report their plain state.
status=starting
i=0
while [ "$i" -lt 30 ]; do
  status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)
  [ "$status" = healthy ] && break
  [ "$status" = exited ] && break
  i=$((i + 1))
  sleep 1
done

if [ "$status" != healthy ]; then
  echo "The container did not become healthy (status: $status)." >&2
  exit 1
fi

echo "Restarted CLIProxyAPI."
