#!/bin/sh
# Download and verify a CLIProxyAPI release for use by the container image.
set -eu

usage() {
  echo "Usage: $0 VERSION TARGETARCH DESTINATION" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage

version=${1#v}
target_arch=$2
destination=$3

case "$version" in
  ''|*[!0-9A-Za-z._-]*)
    echo "Invalid CLIProxyAPI version: $1" >&2
    exit 2
    ;;
esac

case "$target_arch" in
  amd64) asset_arch=amd64 ;;
  arm64) asset_arch=aarch64 ;;
  *)
    echo "Unsupported container architecture: $target_arch" >&2
    exit 2
    ;;
esac

archive="CLIProxyAPI_${version}_linux_${asset_arch}.tar.gz"
release_url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${version}"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

curl --fail --location --retry 3 --retry-all-errors \
  --output "$tmp_dir/$archive" "$release_url/$archive"
curl --fail --location --retry 3 --retry-all-errors \
  --output "$tmp_dir/checksums.txt" "$release_url/checksums.txt"

expected=$(awk -v file="$archive" '$2 == file { print $1; exit }' "$tmp_dir/checksums.txt")
if [ -z "$expected" ]; then
  echo "No checksum was published for $archive" >&2
  exit 1
fi

actual=$(sha256sum "$tmp_dir/$archive" | awk '{ print $1 }')
if [ "$actual" != "$expected" ]; then
  echo "Checksum verification failed for $archive" >&2
  exit 1
fi

tar -xzf "$tmp_dir/$archive" -C "$tmp_dir" cli-proxy-api
install -D -m 0755 "$tmp_dir/cli-proxy-api" "$destination"
