#!/bin/sh
# Run install.sh without Docker and check where it writes things. Generates
# no containers and needs only the scripts present in the working tree.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

fail() {
  echo "test failed: $1" >&2
  exit 1
}

perm_is() {
  path=$1
  want=$2
  got=$(stat -Lc '%a' "$path")
  [ "$got" = "$want" ] || fail "$path has mode $got, wanted $want"
}

# install.sh needs a project directory; copy the working tree there so the
# real checkout never gains a .env or config.yaml.
stage() {
  copy=$(mktemp -d)
  (cd "$repo" && tar -c -f - --exclude=./.git --exclude=./node_modules .) \
    | (cd "$copy" && tar -x -f -)
}

XDG_CONFIG_HOME=$(mktemp -d)
XDG_DATA_HOME=$(mktemp -d)
XDG_STATE_HOME=$(mktemp -d)
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
home=$(mktemp -d)
conf_dir=$XDG_CONFIG_HOME/cli-api-proxy
data_dir=$XDG_DATA_HOME/cli-api-proxy
state_dir=$XDG_STATE_HOME/cli-api-proxy

stage
cd "$copy"
sh ./install.sh --no-start >/dev/null

# Generated configuration lives in the XDG config directory, not the project.
[ -f "$conf_dir/config.yaml" ] || fail 'config.yaml missing from XDG config dir'
[ -f "$conf_dir/credentials.txt" ] || fail 'credentials.txt missing from XDG config dir'
perm_is "$conf_dir/config.yaml" 600
perm_is "$conf_dir/credentials.txt" 600
perm_is "$conf_dir" 700

grep -q '__MANAGEMENT_SECRET__' "$conf_dir/config.yaml" \
  && fail 'config.yaml still contains the placeholder secret'
grep -q 'secret-key: "' "$conf_dir/config.yaml" \
  || fail 'config.yaml has no generated secret-key'

# Data goes to XDG data, logs to XDG state.
for sub in auths plugins static; do
  [ -d "$data_dir/$sub" ] || fail "$sub missing from XDG data dir"
done
[ -d "$state_dir/logs" ] || fail 'logs missing from XDG state dir'
perm_is "$data_dir" 700
perm_is "$state_dir/logs" 700

[ ! -e "$copy/config/config.yaml" ] || fail 'config.yaml must not be created in the project dir'
[ ! -e "$copy/data/auths" ] || fail 'data/auths must not be created in the project dir'

# .env stays beside compose.yaml but records the resolved XDG paths so Compose
# works even when XDG_ variables are not set in its runtime environment.
perm_is "$copy/.env" 600
grep -Fx "CLI_PROXY_CONFIG_DIR=$conf_dir" "$copy/.env" \
  || fail '.env does not record the XDG config dir'
grep -Fx "CLI_PROXY_DATA_DIR=$data_dir" "$copy/.env" \
  || fail '.env does not record the XDG data dir'
grep -Fx "CLI_PROXY_STATE_DIR=$state_dir" "$copy/.env" \
  || fail '.env does not record the XDG state dir'

# A pre-XDG install keeping config/ and data/ beside the project migrates over.
rm -rf "$conf_dir" "$data_dir" "$state_dir"
stage
cd "$copy"
mkdir -p config data/auths data/logs
printf 'secret-key: "legacy"\n' > config/config.yaml
printf 'x\n' > data/auths/legacy-token.txt
printf 'old log\n' > data/logs/legacy.log
sh ./install.sh --no-start >/dev/null

[ ! -f "$copy/config/config.yaml" ] || fail 'legacy config.yaml was not migrated out of the project dir'
grep -q 'secret-key: "legacy"' "$conf_dir/config.yaml" \
  || fail 'the legacy config.yaml content was not carried over'
[ -f "$data_dir/auths/legacy-token.txt" ] || fail 'legacy auth file was not migrated to XDG data'
[ -f "$state_dir/logs/legacy.log" ] || fail 'legacy log was not migrated to XDG state'

rm -rf "$conf_dir" "$data_dir" "$state_dir" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$home"
rm -rf "$copy"

echo "xdg-layout: all checks passed"
