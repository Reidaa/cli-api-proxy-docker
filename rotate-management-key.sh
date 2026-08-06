#!/bin/sh
# Replace the CLIProxyAPI management key without changing other configuration.
set -eu

usage() {
  cat <<'EOF'
Usage: ./rotate-management-key.sh [--no-restart]

The script generates a new key and restarts a running CLIProxyAPI container.
Set MANAGEMENT_SECRET to use a specific key without placing it in command history.

Options:
  --no-restart  Change the key without restarting the container.
EOF
}

restart=true
for arg in "$@"; do
  case "$arg" in
    --no-restart) restart=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root_dir"
umask 077

config_file=config/config.yaml
credentials_file=config/credentials.txt
if [ ! -f "$config_file" ]; then
  echo "$config_file does not exist. Run ./install.sh first." >&2
  exit 1
fi

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

new_secret=${MANAGEMENT_SECRET:-$(random_secret)}
if ! printf '%s\n' "$new_secret" | grep -Eq '^[A-Za-z0-9._~-]{16,}$'; then
  echo "MANAGEMENT_SECRET must contain at least 16 letters, numbers, or . _ ~ - characters." >&2
  exit 2
fi

config_tmp=$(mktemp config/.config.yaml.rotate.XXXXXX)
credentials_tmp=
cleanup() {
  rm -f "$config_tmp"
  if [ -n "$credentials_tmp" ]; then
    rm -f "$credentials_tmp"
  fi
}
trap cleanup EXIT HUP INT TERM

if ! awk -v secret="$new_secret" '
  /^remote-management:[[:space:]]*(#.*)?$/ {
    in_remote = 1
    print
    next
  }
  in_remote && /^[^[:space:]#]/ {
    in_remote = 0
  }
  in_remote && /^[[:space:]]+secret-key:[[:space:]]*/ {
    match($0, /^[[:space:]]*/)
    indent = substr($0, 1, RLENGTH)
    print indent "secret-key: \"" secret "\""
    changed = 1
    next
  }
  { print }
  END {
    if (!changed) exit 42
  }
' "$config_file" > "$config_tmp"; then
  echo "Could not find remote-management.secret-key in $config_file." >&2
  exit 1
fi

backup="$config_file.backup.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$config_file" "$backup"
# Write through the existing file so that Docker's file bind mount sees the change.
cat "$config_tmp" > "$config_file"
chmod 600 "$config_file"

credentials_tmp=$(mktemp config/.credentials.rotate.XXXXXX)
if [ -f "$credentials_file" ]; then
  awk -v secret="$new_secret" '
    /^Management UI password:[[:space:]]*/ {
      print "Management UI password: " secret
      changed = 1
      next
    }
    { print }
    END {
      if (!changed) print "Management UI password: " secret
    }
  ' "$credentials_file" > "$credentials_tmp"
else
  printf 'Management UI password: %s\n' "$new_secret" > "$credentials_tmp"
fi
cat "$credentials_tmp" > "$credentials_file"
chmod 600 "$credentials_file"

if [ "$restart" = true ] && command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  container_id=$(docker compose ps -q cli-api-proxy 2>/dev/null || true)
  if [ -n "$container_id" ] && [ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" = true ]; then
    docker compose restart cli-api-proxy
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
      echo "The key changed, but the container did not become healthy (status: $status)." >&2
      exit 1
    fi
    echo "Restarted CLIProxyAPI."
  else
    echo "CLIProxyAPI is not running. The new key applies at the next start."
  fi
elif [ "$restart" = true ]; then
  echo "Docker Compose is unavailable. The new key applies at the next start."
else
  echo "The container was not restarted. CLIProxyAPI can load the changed file automatically."
fi

echo "The old management key is no longer valid."
echo "New management key: $new_secret"
echo "Saved the new key in $credentials_file."
echo "Saved the previous hashed configuration in $backup."
