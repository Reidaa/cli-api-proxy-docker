#!/bin/sh
# Stop CLIProxyAPI and remove the installed project files. Run from an
# installed copy (the directory the bootstrap created) or from uninstall
# through the one-liner:
#   curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s -- --uninstall
#
# By default the XDG user data is kept (config in ~/.config/cli-api-proxy,
# data in ~/.local/share/cli-api-proxy, logs in ~/.local/state/cli-api-proxy),
# because provider auth tokens are stored there and are hard to recreate.
# Pass --purge to delete those directories too.
set -eu

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--purge]

Options:
  --purge  Also delete the XDG config, data and state directories.
           This includes provider auth tokens and the management password.
  -h --help  Show this help.
EOF
}

purge=false
for arg in "$@"; do
  case "$arg" in
    --purge) purge=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Check this before touching anything: a git checkout is someone's source
# tree, and --purge would also delete their real auth tokens.
if [ -e "$root_dir/.git" ]; then
  echo "Refusing to uninstall from a git checkout." >&2
  echo "Nothing was removed. Run uninstall.sh from an installed copy instead." >&2
  exit 2
fi
conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/cli-api-proxy
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}/cli-api-proxy
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/cli-api-proxy

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  container_id=$(cd "$root_dir" && docker compose ps -q cli-api-proxy 2>/dev/null || true)
  if [ -n "$container_id" ]; then
    if (cd "$root_dir" && docker compose down --remove-orphans >/dev/null 2>&1); then
      echo "Stopped the CLIProxyAPI container."
    else
      echo "Docker Compose could not stop the container." >&2
      echo "If 'cli-api-proxy' is still running, stop it manually (docker rm -f cli-api-proxy)." >&2
    fi
  fi
else
  echo "Docker Compose is unavailable. If 'cli-api-proxy' is running, stop it manually (docker rm -f cli-api-proxy)." >&2
fi

# A git checkout never reaches this point: the guard above aborts first.
echo "Removing the project files in $root_dir"
rm -rf "$root_dir"

if $purge; then
  echo "Removing the generated config, data and state directories."
  rm -rf "$conf_dir" "$data_dir" "$state_dir"
else
  echo
  echo "Kept (drop these manually to lose auth tokens and settings):"
  echo "  $conf_dir"
  echo "  $data_dir"
  echo "  $state_dir"
  echo "Run again with --purge to delete them."
fi

echo
echo "To reinstall, run:"
echo "  curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s --"
