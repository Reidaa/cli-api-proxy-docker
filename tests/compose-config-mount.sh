#!/bin/sh
# Run compose against an installed tree and check the mounts use the XDG
# directories recorded in .env. Needs the docker CLI for "compose config";
# no daemon interaction happens except through config rendering.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
critical=$(mktemp -d)
copy=$(mktemp -d)
trap 'rm -rf "$copy" "$critical"' EXIT

cd "$repo" && tar -c -f - --exclude=./.git --exclude=./node_modules . \
  | (cd "$copy" && tar -x -f -)

XDG_CONFIG_HOME=$(mktemp -d)
XDG_DATA_HOME=$(mktemp -d)
XDG_STATE_HOME=$(mktemp -d)
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
cd "$copy"
sh ./install.sh --no-start >/dev/null

rendered=$(docker compose config)
conf_dir=$XDG_CONFIG_HOME/cli-api-proxy
data_dir=$XDG_DATA_HOME/cli-api-proxy
state_dir=$XDG_STATE_HOME/cli-api-proxy

fail() {
  echo "test failed: $1" >&2
  exit 1
}

printf '%s\n' "$rendered" | grep -Fx "        source: $conf_dir" >/dev/null \
  || fail 'config mount source must be the XDG config dir'
printf '%s\n' "$rendered" | grep -Fx "        target: /config" >/dev/null \
  || fail 'config mount target must be /config'
printf '%s\n' "$rendered" | grep -Fx "        source: $data_dir" >/dev/null \
  || fail 'data mount source must be the XDG data dir'
printf '%s\n' "$rendered" | grep -Fx "        target: /data" >/dev/null \
  || fail 'data mount target must be /data'
printf '%s\n' "$rendered" | grep -Fx "        source: $state_dir/logs" >/dev/null \
  || fail 'log mount source must be the XDG state logs dir'
printf '%s\n' "$rendered" | grep -Fx "        target: /data/logs" >/dev/null \
  || fail 'log mount target must be /data/logs'

# Every bind mount must carry the :z SELinux relabel so the container can
# read the mounted files on enforcing hosts such as Fedora CoreOS. Without
# it the proxy cannot load its configuration and crash-loops.
printf '%s\n' "$rendered" | awk '
  /^        target: / { target=$2 }
  /^          selinux: z$/ { print target }
' > selinux_targets
for target in /config /data /data/logs; do
  grep -Fx "$target" selinux_targets >/dev/null \
    || fail "the $target mount must include the :z SELinux relabel"
done

# A bare config.yaml mount would break the management UI validation writes.
if printf '%s\n' "$rendered" | grep -F "target: /config/config.yaml" >/dev/null; then
  fail 'config.yaml must not be mounted without its writable parent directory'
fi

rm -rf "$conf_dir" "$data_dir" "$state_dir" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

echo "compose-config-mount: all checks passed"
