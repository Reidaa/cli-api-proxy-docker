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
  --archive PATH  Install from a local tarball instead of downloading.
  -h, --help      Show this help.

Re-running the script on a host that already has an install updates it in
place: fresh project files replace the old ones, and the generated .env and
container data trees are kept.
EOF
}

install_dir=${CLI_PROXY_HOME:-${XDG_DATA_HOME:-${HOME:-.}/.local/share}/cli-api-proxy}
owner=Reidaa
repo=cli-api-proxy-docker
ref=main
mode=install
archive=
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
        --dir|--version|--archive|--no-start|--reconfigure|--uninstall|--purge|--tailscale|-h|--help|'')
          echo "Invalid value for --version: $2" >&2
          exit 2
          ;;
      esac
      ref=$2
      shift 2
      ;;
    --archive)
      [ "$#" -ge 2 ] || { echo "Option --archive needs a value." >&2; exit 2; }
      case "$2" in
        --dir|--version|--archive|--no-start|--reconfigure|--uninstall|--purge|--tailscale|-h|--help|'')
          echo "Invalid value for --archive: $2" >&2
          exit 2
          ;;
      esac
      archive=$2
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
  if [ -n "$archive" ]; then
    fail_exit "--archive does not make sense with --uninstall."
  fi
  case "$inner_flags" in
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

tarball_file=$tmp_dir/source.tar.gz
if [ -n "$archive" ]; then
  [ -f "$archive" ] || fail_exit "Archive not found: $archive"
  tarball_file=$archive
fi

# A git checkout (including worktrees and submodules, where .git is a file
# containing "gitdir: ...") is updated with git alone. No archive is fetched
# for it, so no network work happens beyond the fetch itself.
if [ -d "$install_dir/.git" ] || [ -f "$install_dir/.git" ]; then
  echo "Updating the git checkout in $install_dir ..."
  command -v git >/dev/null 2>&1 \
    || fail_exit "Updating a git checkout needs git, but it was not found in PATH."
  git -C "$install_dir" fetch --tags --force origin "$ref" \
    || fail_exit "Fetching $ref from origin in $install_dir failed."
  git -C "$install_dir" reset --hard FETCH_HEAD
  echo "Updated the project files in $install_dir"
  cd "$install_dir"
  # shellcheck disable=SC2086
  sh ./install.sh $inner_flags
  exit 0
fi

# Elsewhere the archive is downloaded (or taken from --archive) and
# extracted into a scratch staging directory first. Only an intact staging
# tree (tar succeeded, install.sh present) may replace the project files, so
# a corrupt or truncated download can never leave a half-destroyed install
# behind.
if [ -n "$archive" ]; then
  echo "Installing from the local archive $archive"
else
  echo "Downloading $owner/$repo ($ref) ..."
  fetch "$tarball_url" > "$tarball_file"
fi
staging=$tmp_dir/staging
mkdir -p "$staging"
tar -xzf "$tarball_file" -C "$staging" --strip-components=1
[ -f "$staging/install.sh" ] \
  || fail_exit "The source archive has no install.sh; leaving the existing install untouched."

# A previous run leaves generated files in the install directory (.env with
# the resolved XDG paths; the container-owned auths, plugins, static, logs
# and legacy data/config trees; and, when the XDG bases overlap the install
# directory, the config.yaml, credentials.txt and config.yaml backups of the
# XDG layout). An update keeps those, removes everything else, then copies in
# the staged files so sources deleted upstream do not linger. Broken
# symlinks count as entries too (-e cannot see them). rm -rf removes only
# the link of a symlinked entry, never its target, so no check can be made
# to follow a link outside the tree.
mkdir -p "$install_dir"
for entry in "$install_dir"/* "$install_dir"/.[!.]* "$install_dir"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  case ${entry##*/} in
    .env|auths|plugins|static|logs|data|config) continue ;;
    config.yaml|credentials.txt) continue ;;
    config.yaml.backup.*) continue ;;
  esac
  rm -rf -- "$entry"
done

# The staged tree is pruned of anything generated before the copy, so no
# archive can smuggle kept state out of the keep-list (.env, tokens,
# credentials). Only project source files may win.
for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  case ${entry##*/} in
    .env|auths|plugins|static|logs) rm -rf -- "$entry" ;;
    config.yaml|credentials.txt|config.yaml.backup.*) rm -rf -- "$entry" ;;
    data)
      [ -d "$entry" ] && [ ! -L "$entry" ] || { rm -rf -- "$entry"; continue; }
      for child in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
        [ -e "$child" ] || [ -L "$child" ] || continue
        case ${child##*/} in
          .gitkeep) continue ;;
        esac
        rm -rf -- "$child"
      done
      ;;
    config)
      [ -d "$entry" ] && [ ! -L "$entry" ] || { rm -rf -- "$entry"; continue; }
      rm -rf -- "$entry"/config.yaml "$entry"/config.yaml.backup.* \
        "$entry"/credentials.txt
      ;;
  esac
done

tar -cf - -C "$staging" . | tar -xf - -C "$install_dir"
echo "Installed files in $install_dir"
cd "$install_dir"

# shellcheck disable=SC2086
sh ./install.sh $inner_flags
