#!/bin/sh
# Check the --tailscale option: address resolution, the .env updates, and the
# Compose port rendering. No real Tailscale or Docker daemon is needed beyond
# "docker compose config" rendering.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

fail() {
  echo "test failed: $1" >&2
  exit 1
}

stage() {
  copy=$(mktemp -d)
  (cd "$repo" && tar -c -f - --exclude=./.git --exclude=./node_modules .) \
    | (cd "$copy" && tar -x -f -)
}

# Stub binaries come first on PATH so install.sh sees the fake tailscale/ip
# while every other command still resolves normally.
bin=$(mktemp -d)
make_stub() {
  name=$1
  shift
  printf '#!/bin/sh\n' > "$bin/$name"
  printf '%s\n' "$@" >> "$bin/$name"
  chmod +x "$bin/$name"
}

XDG_CONFIG_HOME=$(mktemp -d)
XDG_DATA_HOME=$(mktemp -d)
XDG_STATE_HOME=$(mktemp -d)
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME

# --help documents the option.
"$repo/install.sh" --help | grep -q -- '--tailscale' \
  || fail 'install.sh --help must document --tailscale'

# No Tailscale on the host: refuse with a setup hint, before writing .env.
make_stub tailscale 'exit 1'
make_stub ip 'exit 1'
stage
cd "$copy"
if PATH="$bin:$PATH" sh ./install.sh --no-start --tailscale >/dev/null 2>&1; then
  fail 'install must fail when Tailscale cannot be resolved'
fi
PATH="$bin:$PATH" sh ./install.sh --no-start --tailscale 2>&1 | grep -q 'tailscale up' \
  || fail 'the failure must point to setting Tailscale up'

# A resolvable address lands in .env as BIND_ADDRESS.
make_stub tailscale 'echo 100.64.0.1'
rm -rf "${XDG_CONFIG_HOME:?}"/* "${XDG_DATA_HOME:?}"/* "${XDG_STATE_HOME:?}"/*
stage
cd "$copy"
PATH="$bin:$PATH" sh ./install.sh --no-start --tailscale >/dev/null
grep -Fx 'BIND_ADDRESS=100.64.0.1' .env \
  || fail '.env must record the tailscale address as BIND_ADDRESS'

# Re-running with --tailscale updates an existing .env in place.
make_stub tailscale 'echo 100.64.0.2'
PATH="$bin:$PATH" sh ./install.sh --no-start --tailscale >/dev/null
grep -Fx 'BIND_ADDRESS=100.64.0.2' .env \
  || fail 'an existing .env must have BIND_ADDRESS updated'

# An address outside the Tailscale CGNAT range must be rejected.
make_stub tailscale 'echo 192.168.1.5'
rm -rf "${XDG_CONFIG_HOME:?}"/* "${XDG_DATA_HOME:?}"/* "${XDG_STATE_HOME:?}"/*
stage
cd "$copy"
if PATH="$bin:$PATH" sh ./install.sh --no-start --tailscale >/dev/null 2>&1; then
  fail 'an address outside 100.64.0.0/10 must be rejected'
fi

# The default without the flag stays on loopback, and Compose publishes the
# recorded address on every mapped port.
make_stub tailscale 'echo 100.64.0.1'
rm -rf "${XDG_CONFIG_HOME:?}"/* "${XDG_DATA_HOME:?}"/* "${XDG_STATE_HOME:?}"/*
stage
cd "$copy"
sh ./install.sh --no-start >/dev/null
grep -Fx 'BIND_ADDRESS=127.0.0.1' .env \
  || fail 'without --tailscale the default must stay 127.0.0.1'

PATH="$bin:$PATH" sh ./install.sh --no-start --tailscale >/dev/null
rendered=$(docker compose config)
count=$(printf '%s\n' "$rendered" | grep -Fc 'host_ip: 100.64.0.1')
[ "$count" -eq 6 ] || fail "expected 6 ports published on the tailscale address, got $count"
if printf '%s\n' "$rendered" | grep -Fq 'host_ip: 127.0.0.1'; then
  fail 'no port may stay on loopback when the tailscale address is set'
fi

rm -rf "$bin" "$copy" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
echo "tailscale: all checks passed"
