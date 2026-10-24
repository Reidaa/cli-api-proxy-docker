#!/bin/sh
# Check the argument and dependency handling of bootstrap.sh before any download
# happens. No network access and no Docker work is needed for these cases.
set -eu

root_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
bootstrap="$root_dir/bootstrap.sh"

# An empty PATH hides docker and compose so the dependency check takes its
# "missing Docker" path without touching the real environment. Env must be
# called with an absolute shell path because env itself resolves programs
# using the new PATH.
stub_path=$(mktemp -d)
trap 'rm -rf "$stub_path"' EXIT

fail() {
  echo "test failed: $1" >&2
  exit 1
}

# --help exits 0 and shows usage.
"$bootstrap" --help | grep -q -- '--dir' || fail '--help must show the --dir option'
"$bootstrap" --help | grep -q -- '--tailscale' || fail '--help must show the --tailscale option'

# An unknown argument exits 2 with a usage hint.
"$bootstrap" --bogus 2>/dev/null && fail 'unknown option must fail'
"$bootstrap" --bogus 2>&1 | grep -q 'Unknown option' || fail 'error must name the bad option'

# Missing Docker exits 1 with a fix hint, before any download could start.
PATH="$stub_path" /bin/sh "$bootstrap" 2>&1 | grep -q 'get.docker.com' \
  || fail 'missing Docker must point to get.docker.com'
PATH="$stub_path" /bin/sh "$bootstrap" >/dev/null 2>&1 && \
  fail 'missing Docker must exit non-zero'

echo "bootstrap-args: all checks passed"
