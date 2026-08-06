#!/bin/sh
# Verify the management UI can create validation files beside its configuration.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$root_dir"

rendered=$(docker compose config)

printf '%s\n' "$rendered" | grep -Fx "        source: $root_dir/config" >/dev/null
printf '%s\n' "$rendered" | grep -Fx "        target: /config" >/dev/null
if printf '%s\n' "$rendered" | grep -F "target: /config/config.yaml" >/dev/null; then
  echo "config.yaml must not be mounted without its writable parent directory" >&2
  exit 1
fi
