#!/bin/sh
# Configure and start CLIProxyAPI with Docker Compose.
set -eu

usage() {
  cat <<'EOF'
Usage: ./install.sh [--reconfigure] [--no-start]

Options:
  --reconfigure  Back up and replace the existing config/config.yaml.
  --no-start     Create the configuration without building or starting Docker.

Optional environment variables:
  MANAGEMENT_SECRET      Management UI password (16 or more safe characters).
  ALLOW_REMOTE_MANAGEMENT true or false (default: true for Docker networking).
EOF
}

reconfigure=false
start=true
for arg in "$@"; do
  case "$arg" in
    --reconfigure) reconfigure=true ;;
    --no-start) start=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root_dir"
umask 077

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

mkdir -p config data/auths data/logs data/plugins data/static
chmod 700 config data data/auths data/logs data/plugins data/static

created_config=false
if [ -f config/config.yaml ] && [ "$reconfigure" = true ]; then
  backup="config/config.yaml.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p config/config.yaml "$backup"
  echo "Backed up the existing configuration to $backup"
  rm -f config/config.yaml
fi

if [ ! -f config/config.yaml ]; then
  management_secret=${MANAGEMENT_SECRET:-$(random_secret)}
  validate_secret MANAGEMENT_SECRET "$management_secret"

  sed \
    -e "s|__MANAGEMENT_SECRET__|$management_secret|g" \
    -e "s|__ALLOW_REMOTE_MANAGEMENT__|$allow_remote|g" \
    config/config.yaml.example > config/config.yaml
  chmod 600 config/config.yaml

  cat > config/credentials.txt <<EOF
Management UI password: $management_secret
EOF
  chmod 600 config/credentials.txt
  created_config=true
  echo "Created config/config.yaml and config/credentials.txt"
else
  echo "Keeping the existing config/config.yaml"
fi

if [ ! -f .env ]; then
  cat > .env <<EOF
CLI_PROXY_VERSION=7.2.121
BIND_ADDRESS=127.0.0.1
CLI_PROXY_PORT=8317
TZ=${TZ:-UTC}
HOST_UID=$(id -u)
HOST_GID=$(id -g)
EOF
  chmod 600 .env
  echo "Created .env for user $(id -u):$(id -g)"
fi

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
echo "CLIProxyAPI is starting at http://127.0.0.1:8317"
echo "Management UI: http://127.0.0.1:8317/management.html"
echo "Check status with: docker compose ps"
echo "Follow logs with:  docker compose logs -f cli-api-proxy"
if [ "$created_config" = true ]; then
  echo "The management password was saved to config/credentials.txt (mode 600)."
fi
