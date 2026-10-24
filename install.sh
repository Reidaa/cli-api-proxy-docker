#!/bin/sh
# Configure and start CLIProxyAPI with Docker Compose.
# Generated files live in XDG base directories, separate from the project
# files in this directory:
#   config  $XDG_CONFIG_HOME/cli-api-proxy  (config.yaml, credentials.txt)
#   data    $XDG_DATA_HOME/cli-api-proxy    (auths, plugins, static)
#   state   $XDG_STATE_HOME/cli-api-proxy   (logs)
# The resolved paths are recorded in .env so Compose finds them even when the
# XDG_ variables are not set in its own runtime environment.
set -eu

usage() {
  cat <<'EOF'
Usage: ./install.sh [--reconfigure] [--no-start] [--tailscale]

Options:
  --reconfigure  Back up and replace the existing config.yaml.
  --no-start     Create the configuration without building or starting Docker.
  --tailscale    Bind all published ports to this host's Tailscale address,
                 so only machines on the tailnet can reach the service.

Optional environment variables:
  MANAGEMENT_SECRET        Management UI password (16 or more safe characters).
  ALLOW_REMOTE_MANAGEMENT  true or false (default: true for Docker networking).
  XDG_CONFIG_HOME          Base for the config files (default: ~/.config).
  XDG_DATA_HOME            Base for auths, plugins, static (default: ~/.local/share).
  XDG_STATE_HOME           Base for the logs (default: ~/.local/state).
EOF
}

reconfigure=false
start=true
tailscale=false
for arg in "$@"; do
  case "$arg" in
    --reconfigure) reconfigure=true ;;
    --no-start) start=false ;;
    --tailscale) tailscale=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$root_dir"
umask 077

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
state_home=${XDG_STATE_HOME:-$HOME/.local/state}
conf_dir=$config_home/cli-api-proxy
data_dir=$data_home/cli-api-proxy
state_dir=$state_home/cli-api-proxy

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

validate_secret() {
  name=$1
  value=$2
  if ! printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9._~-]{16,}$'; then
    echo "$name must contain at least 16 letters, numbers, or . _ ~ - characters." >&2
    exit 2
  fi
}

allow_remote=${ALLOW_REMOTE_MANAGEMENT:-true}
case "$allow_remote" in
  true|false) ;;
  *) echo "ALLOW_REMOTE_MANAGEMENT must be true or false." >&2; exit 2 ;;
esac

# Resolve this host's Tailscale address from the CLI, or from the tailscale0
# interface when the CLI is absent. Anything outside the CGNAT range is
# refused so a broken resolver cannot silently expose the ports elsewhere.
bind_address=127.0.0.1
if [ "$tailscale" = true ]; then
  ts_ip=
  if command -v tailscale >/dev/null 2>&1; then
    ts_ip=$(tailscale ip -4 2>/dev/null || true)
  fi
  if [ -z "$ts_ip" ] && command -v ip >/dev/null 2>&1; then
    ts_ip=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | head -n 1)
    ts_ip=${ts_ip%/*}
  fi
  if [ -z "$ts_ip" ] \
    || ! printf '%s\n' "$ts_ip" | grep -Eq '^100(\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))(\.[0-9]{1,3}){2}$'; then
    echo "No Tailscale address was found on this host." >&2
    echo "Install Tailscale, run 'tailscale up', then re-run with --tailscale." >&2
    echo "Without it, the ports stay bound to 127.0.0.1." >&2
    exit 1
  fi
  bind_address=$ts_ip
  echo "Binding all published ports to the Tailscale address $bind_address"
fi

mkdir -p "$conf_dir" "$data_dir/auths" "$data_dir/plugins" "$data_dir/static" "$state_dir/logs"
chmod 700 "$conf_dir" "$data_dir" "$data_dir/auths" "$data_dir/plugins" "$data_dir/static" "$state_dir" "$state_dir/logs"

# Move an existing pre-XDG installation (which kept everything beside the
# project files) over to the XDG directories. Globs expand into multiple
# source names, so each entry moves individually when the target is empty.
migrate_file() {
  src=$1
  dest=$2
  if [ -e "$src" ] && [ ! -e "$dest" ]; then
    echo "Migrating $src to $dest"
    mv "$src" "$dest"
  fi
}
migrate_file config/config.yaml "$conf_dir/config.yaml"
migrate_file config/credentials.txt "$conf_dir/credentials.txt"
for src in data/auths/*; do
  [ -e "$src" ] || continue
  mv "$src" "$data_dir/auths/"
  echo "Migrating $src to $data_dir/auths/"
done
for src in data/plugins/*; do
  [ -e "$src" ] || continue
  mv "$src" "$data_dir/plugins/"
  echo "Migrating $src to $data_dir/plugins/"
done
for src in data/static/*; do
  [ -e "$src" ] || continue
  mv "$src" "$data_dir/static/"
  echo "Migrating $src to $data_dir/static/"
done
for src in data/logs/*; do
  [ -e "$src" ] || continue
  mv "$src" "$state_dir/logs/"
  echo "Migrating $src to $state_dir/logs/"
done

created_config=false
if [ -f "$conf_dir/config.yaml" ] && [ "$reconfigure" = true ]; then
  backup="$conf_dir/config.yaml.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$conf_dir/config.yaml" "$backup"
  echo "Backed up the existing configuration to $backup"
  rm -f "$conf_dir/config.yaml"
fi

if [ ! -f "$conf_dir/config.yaml" ]; then
  management_secret=${MANAGEMENT_SECRET:-$(random_secret)}
  validate_secret MANAGEMENT_SECRET "$management_secret"

  sed \
    -e "s|__MANAGEMENT_SECRET__|$management_secret|g" \
    -e "s|__ALLOW_REMOTE_MANAGEMENT__|$allow_remote|g" \
    config/config.yaml.example > "$conf_dir/config.yaml"
  chmod 600 "$conf_dir/config.yaml"

  printf 'Management UI password: %s\n' "$management_secret" > "$conf_dir/credentials.txt"
  chmod 600 "$conf_dir/credentials.txt"
  created_config=true
  echo "Created $conf_dir/config.yaml and $conf_dir/credentials.txt"
else
  echo "Keeping the existing $conf_dir/config.yaml"
fi

# .env lives beside compose.yaml (its only auto-discovery location) and needs
# the resolved XDG paths for the volume mounts. The release version stays out
# of it: compose.yaml owns the default, and a user adds CLI_PROXY_VERSION here
# only to pin a different release.
if [ ! -f .env ]; then
  {
    printf 'BIND_ADDRESS=%s\n' "$bind_address"
    printf 'CLI_PROXY_PORT=8317\n'
    printf 'TZ=%s\n' "${TZ:-UTC}"
    printf 'HOST_UID=%s\n' "$(id -u)"
    printf 'HOST_GID=%s\n' "$(id -g)"
    printf 'CLI_PROXY_CONFIG_DIR=%s\n' "$conf_dir"
    printf 'CLI_PROXY_DATA_DIR=%s\n' "$data_dir"
    printf 'CLI_PROXY_STATE_DIR=%s\n' "$state_dir"
  } > .env
  chmod 600 .env
  echo "Created .env for user $(id -u):$(id -g)"
else
  echo "Keeping the existing .env"
  if [ "$tailscale" = true ]; then
    sed -e "s|^BIND_ADDRESS=.*|BIND_ADDRESS=$bind_address|" .env > .env.new
    grep -q '^BIND_ADDRESS=' .env || echo "BIND_ADDRESS=$bind_address" >> .env.new
    mv .env.new .env
    chmod 600 .env
    echo "Updated BIND_ADDRESS to $bind_address in .env"
  fi
fi
bind_address=$(sed -n 's/^BIND_ADDRESS=//p' .env | tail -n 1)
: "${bind_address:=127.0.0.1}"

if [ "$start" = false ]; then
  echo "Configuration is ready. Run 'docker compose up -d --build' to start it."
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required but was not found in PATH." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required (the 'docker compose' command)." >&2
  exit 1
fi

docker compose config --quiet
docker compose up --detach --build

echo
echo "CLIProxyAPI is starting at http://$bind_address:8317"
echo "Management UI: http://$bind_address:8317/management.html"
if [ "$bind_address" != 127.0.0.1 ]; then
  echo "The service is bound to $bind_address, so http://127.0.0.1:8317 no longer answers."
  echo "Use this address from this machine too, or the MagicDNS name of this host."
fi
echo "Check status with: docker compose ps"
echo "Follow logs with:  docker compose logs -f cli-api-proxy"
if [ "$created_config" = true ]; then
  echo "The management password was saved to $conf_dir/credentials.txt (mode 600)."
fi
