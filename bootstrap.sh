#!/bin/sh
# Install CLIProxyAPI in Docker on any machine. Designed to be piped:
#   curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s --
# The script downloads the repository tarball from GitHub, extracts it into the
# install directory, and runs install.sh from there for the real work
# (configuration, build, start). Generated files live in XDG base directories
# and are kept when the script is re-run.
set -eu

usage() {
  cat <<'EOF'
Install CLIProxyAPI with Docker in one line:

  curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s --

Options (after "sh -s --"):
  --dir PATH      Install directory (default: $XDG_DATA_HOME/cli-api-proxy).
  --version TAG   GitHub tag or branch to install (default: main).
  --uninstall     Stop the service and remove the installed project files.
                  Pass --purge with --uninstall to also delete the XDG config,
                  data and state directories (this includes provider auth
                  tokens, so it is opt-in).
  --no-start      Configure only; skip the Docker build and start.
  --tailscale     Bind all published ports to this host's Tailscale address.
  --reconfigure   Back up and replace the existing config.yaml.
  -h, --help      Show this help.
EOF
}

install_dir=${CLI_PROXY_HOME:-${XDG_DATA_HOME:-${HOME:-.}/.local/share}/cli-api-proxy}
owner=Reidaa
repo=cli-api-proxy-docker
ref=main
mode=install
inner_flags=

# Values are consumed with shift, so no here-document inside a for loop has to
# track two arguments at once. Unknown options exit 2 with usage, matching
# install.sh.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || { echo "Option --dir needs a value." >&2; exit 2; }
      install_dir=$2
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || { echo "Option --version needs a value." >&2; exit 2; }
      case "$2" in
        --dir|--version|--no-start|--reconfigure|--uninstall|--purge|--tailscale|-h|--help|'')
          echo "Invalid value for --version: $2" >&2
          exit 2
          ;;
      esac
      ref=$2
      shift 2
      ;;
    --no-start|--reconfigure|--tailscale)
      inner_flags="${inner_flags:+$inner_flags }$1"
      shift
      ;;
    --uninstall)
      mode=uninstall
      shift
      ;;
    --purge)
      inner_flags="${inner_flags:+$inner_flags }$1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# A piped run may have no writable $HOME (rare but real on root-less hosts).
fail_exit() {
  echo "$1" >&2
  echo "Bootstrap stopped." >&2
  exit 1
}

check_dependencies() {
  if ! command -v docker >/dev/null 2>&1; then
    echo >&2
    echo "Docker is required but was not found in PATH." >&2
    echo "Install Docker Engine first, then re-run this script:" >&2
    echo "  curl -fsSL https://get.docker.com | sh" >&2
    fail_exit ""
  fi
  if ! docker compose version >/dev/null 2>&1; then
    fail_exit "Docker Compose v2 is required (the 'docker compose' command).\
 Older docker-compose v1 binaries are not supported."
  fi
}

# curl or wget, whichever exists. Both print to stdout on success and fail
# hard on HTTP errors so a partial download never reaches tar.
fetch() {
  url=$1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -- "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- -- "$url"
  else
    fail_exit "Neither curl nor wget was found. Install one of them first."
  fi
}

# Uninstall needs the installed files, not a download; reject combinations
# that would fetch code just to remove it.
if [ "$mode" = uninstall ]; then
  case "$inner_flags" in
    --no-start*|*--no-start|--reconfigure*|*--reconfigure|--tailscale*|*--tailscale)
      fail_exit "--no-start, --reconfigure and --tailscale do not make sense with --uninstall."
      ;;
  esac
  if [ -x "$install_dir/uninstall.sh" ]; then
    # shellcheck disable=SC2086
    (cd "$install_dir" && sh ./uninstall.sh $inner_flags)
    exit 0
  fi
  echo "No CLIProxyAPI install found in $install_dir." >&2
  echo "Falling back to container removal by name." >&2
  if command -v docker >/dev/null 2>&1; then
    docker rm --force cli-api-proxy >/dev/null 2>&1 || true
  fi
  conf_dir=${XDG_CONFIG_HOME:-$HOME/.config}/cli-api-proxy
  data_dir=${XDG_DATA_HOME:-$HOME/.local/share}/cli-api-proxy
  state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/cli-api-proxy
  case "$inner_flags" in
    --purge*|*' --purge'*|*'--purge'*)
      rm -rf "$conf_dir" "$data_dir" "$state_dir"
      echo "Removed $conf_dir $data_dir $state_dir"
      ;;
    *)
      echo "Kept $conf_dir" >&2
      echo "Kept $data_dir" >&2
      echo "Kept $state_dir" >&2
      echo "Re-run with --purge to delete them." >&2
      ;;
  esac
  exit 0
fi

check_dependencies

tarball_url="https://codeload.github.com/$owner/$repo/tar.gz/refs/heads/$ref"
case "$ref" in
  main) ;;

  # Tags and other refs have their own codeload URL shape.
  *)
    tarball_url="https://codeload.github.com/$owner/$repo/tar.gz/refs/tags/$ref"
    ;;
esac

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

echo "Downloading $owner/$repo ($ref) ..."
fetch "$tarball_url" > "$tmp_dir/source.tar.gz"

# codeload always wraps the tree in one top directory; strip it so install.sh
# ends up directly under the install directory.
mkdir -p "$install_dir"
tar -xzf "$tmp_dir/source.tar.gz" -C "$install_dir" --strip-components=1

echo "Installed files in $install_dir"
cd "$install_dir"

# shellcheck disable=SC2086
sh ./install.sh $inner_flags
