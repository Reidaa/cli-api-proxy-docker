#!/bin/sh
# Check uninstall.sh behavior with no containers involved: files are removed,
# user data is kept unless --purge is set, and git checkouts are protected.
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

XDG_CONFIG_HOME=$(mktemp -d)
XDG_DATA_HOME=$(mktemp -d)
XDG_STATE_HOME=$(mktemp -d)
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
conf_dir=$XDG_CONFIG_HOME/cli-api-proxy
data_dir=$XDG_DATA_HOME/cli-api-proxy
state_dir=$XDG_STATE_HOME/cli-api-proxy

stage
cd "$copy"
sh ./install.sh --no-start >/dev/null

# Default keeps the XDG user data (auth tokens and settings live there).
sh ./uninstall.sh >/dev/null 2>&1 || fail 'uninstall must succeed with no running container'
[ -f "$conf_dir/config.yaml" ] || fail 'default uninstall must keep the config dir'
[ -d "$data_dir/auths" ] || fail 'default uninstall must keep the data dir'
[ -d "$state_dir/logs" ] || fail 'default uninstall must keep the state dir'

# --purge removes the XDG directories as well (and requires a fresh install
# copy, since the default uninstall above already deleted the code dir).
stage
cd "$copy"
sh ./install.sh --no-start >/dev/null
sh ./uninstall.sh --purge >/dev/null 2>&1 || fail 'uninstall --purge must succeed'
[ ! -e "$conf_dir" ] || fail 'uninstall --purge must remove the config dir'
[ ! -e "$data_dir" ] || fail 'uninstall --purge must remove the data dir'
[ ! -e "$state_dir" ] || fail 'uninstall --purge must remove the state dir'

# A git checkout must refuse to delete itself; the real checkout has .git.
cd "$repo"
sh ./uninstall.sh --purge >/dev/null 2>&1 && \
  fail 'uninstall must refuse to delete a git checkout'
sh ./uninstall.sh --purge 2>&1 | grep -q 'git checkout' \
  || fail 'uninstall must explain why it refused'
test -f ./uninstall.sh || fail 'uninstall removed the git checkout anyway'

# The bootstrap uninstall fallback works without any installed files: it
# removes the container by name and reports the kept XDG directories.
CLI_PROXY_HOME="$XDG_DATA_HOME/gone" sh ./bootstrap.sh --uninstall >/dev/null 2>&1 \
  || fail 'bootstrap --uninstall fallback must succeed'
CLI_PROXY_HOME="$XDG_DATA_HOME/gone" sh ./bootstrap.sh --uninstall 2>&1 | grep -Fq 'Kept' \
  || fail 'bootstrap --uninstall fallback must report kept paths'

rm -rf "$copy" "$conf_dir" "$data_dir" "$state_dir" \
  "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"
echo "uninstall: all checks passed"
