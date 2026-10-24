# CLIProxyAPI container

This project builds and runs [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) in a Docker container.

The image downloads a versioned release and checks its SHA-256 checksum. It supports Linux AMD64 and ARM64 hosts.

## Requirements

Install these components:

- Docker Engine or Docker Desktop
- Docker Compose v2
- A POSIX shell

## Install

On a machine with Docker already, run the one-line installer:

```sh
curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s --
```

The script downloads the project tarball from GitHub and installs it in
`~/.local/share/cli-api-proxy` (follows `$XDG_DATA_HOME`). It then runs the
local installer `install.sh` inside that directory. Re-running the same
one-liner refreshes the project files and keeps your settings.

Generated files do not live in the install directory. They follow the XDG
base directories:

- Config (`config.yaml`, `credentials.txt`): `$XDG_CONFIG_HOME/cli-api-proxy`, `~/.config/cli-api-proxy` by default. Mode `600`.
- Data (`auths`, `plugins`, `static`): `$XDG_DATA_HOME/cli-api-proxy`, `~/.local/share/cli-api-proxy` by default.
- State (rotating logs): `$XDG_STATE_HOME/cli-api-proxy/logs`, `~/.local/state/cli-api-proxy/logs` by default.

The installer records the resolved paths in `.env` next to `compose.yaml`, so
the Compose mounts work even without the `XDG_` variables set.

Options go after `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s -- --dir /srv/cli-api-proxy --version v1.2.3 --no-start
```

- `--dir PATH` sets the install directory (default: `~/.local/share/cli-api-proxy`).
- `--version TAG` installs a GitHub tag instead of the `main` branch.
- `--no-start` configures without building or starting Docker.
- `--tailscale` binds all published ports to this host's Tailscale address; see [Tailscale](#tailscale).
- `--reconfigure` is passed through to `install.sh`.
- `--uninstall --purge` removes the installation; see [Uninstall](#uninstall).

If `docker` or `docker compose` is missing, the script stops before any
download and prints the install hint `curl -fsSL https://get.docker.com | sh`.

## Tailscale

With Tailscale already running on the host, install with the `--tailscale`
option:

```sh
curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s -- --tailscale
```

The installer resolves the host's Tailscale address (`tailscale ip -4`, or the
`tailscale0` interface) and binds every published port to it. Only machines on
your tailnet can reach the service. From any of them, open:

- API: `http://<tailscale-address>:8317`
- Management UI: `http://<tailscale-address>:8317/management.html`

The MagicDNS name of the host works in place of the address. The installer
refuses an address outside the Tailscale CGNAT range (`100.64.0.0/10`) so a
broken resolver cannot expose the ports elsewhere.

Two consequences of the single-address binding:

1. `http://127.0.0.1:8317` no longer answers on the host. Use the Tailscale
   address (or the MagicDNS name) locally as well.
2. The OAuth callback ports move to the Tailscale address with everything
   else. Provider logins that redirect to `localhost` need a tunnel
   (`ssh -L`) or a temporary `BIND_ADDRESS=127.0.0.1` re-run.

If `tailscaled` is stopped, the published binding pauses with it and returns
when Tailscale comes back.

To go back to loopback-only, set `BIND_ADDRESS=127.0.0.1` in `.env` and run
`./install.sh` again.

## Uninstall

Stop the service and delete the installed project files:

```sh
curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s -- --uninstall
```

The XDG config, data and state directories are kept, because they hold
provider auth tokens and the management password. Delete them too:

```sh
curl -fsSL https://raw.githubusercontent.com/Reidaa/cli-api-proxy-docker/main/bootstrap.sh | sh -s -- --uninstall --purge
```

From an installed copy, `./uninstall.sh` and `./uninstall.sh --purge` do the
same. The script refuses to run from a git checkout, so developing against the
source is safe.

### Install from a local checkout

Run the installer:

```sh
./install.sh
```

The installer does these actions:

1. It creates a local configuration.
2. It creates a management password.
3. It builds the container image.
4. It starts the service.

The installer stores the generated management password in `$XDG_CONFIG_HOME/cli-api-proxy/credentials.txt` (default: `~/.config/cli-api-proxy/credentials.txt`). This file has permission mode `600`.

Open these URLs:

- API: <http://127.0.0.1:8317>
- Management UI: <http://127.0.0.1:8317/management.html>

Use the management UI to add provider credentials or start an OAuth login.

## Connect a client

The default configuration does not create a client API key. To require client authentication, add one or more keys to `api-keys` in the generated `config.yaml` (default: `~/.config/cli-api-proxy/config.yaml`).

For an OpenAI-compatible client, use these values:

```text
Base URL: http://127.0.0.1:8317/v1
API key:  <a configured client API key, if required>
```

For an Anthropic-compatible client, use this base URL:

```text
http://127.0.0.1:8317
```

CLIProxyAPI also provides Gemini-compatible routes. Read the [upstream documentation](https://github.com/router-for-me/CLIProxyAPI) for route details.

## Configuration

The installer creates these local files and directories:

| Path | Purpose |
| --- | --- |
| `.env` | The image version, network address, time zone, and host user IDs |
| `$XDG_CONFIG_HOME/cli-api-proxy/config.yaml` | The CLIProxyAPI configuration |
| `$XDG_CONFIG_HOME/cli-api-proxy/credentials.txt` | The generated management password |
| `$XDG_DATA_HOME/cli-api-proxy/auths/` | OAuth tokens and provider credentials |
| `$XDG_STATE_HOME/cli-api-proxy/logs/` | File logs, if file logging is active |
| `data/plugins/` | Optional dynamic plugins |
| `data/static/` | The downloaded management panel |

Edit the generated `config.yaml` (default: `~/.config/cli-api-proxy/config.yaml`) to add advanced provider configuration. The management UI can also change this file and creates temporary validation files beside the configuration while saving.

The template contains only the common configuration. Use the [complete upstream example](https://github.com/router-for-me/CLIProxyAPI/blob/main/config.example.yaml) for all keys.

### Custom management password

Set the management password before the first installation:

```sh
MANAGEMENT_SECRET='replace-with-a-secret-value' ./install.sh
```

The password must contain at least 16 safe ASCII characters. The accepted special characters are `.`, `_`, `~`, and `-`.

### Replace the configuration

CAUTION: The `--reconfigure` option replaces the active configuration. The installer creates a timestamped backup first.

```sh
./install.sh --reconfigure
```

Use `--no-start` to create the files without Docker:

```sh
./install.sh --no-start
```

## Rotate the management key

Run this command:

```sh
./rotate-management-key.sh
```

The script generates a new key and saves it in `$XDG_CONFIG_HOME/cli-api-proxy/credentials.txt`. It also restarts a running container.

Set `MANAGEMENT_SECRET` to select the new key:

```sh
MANAGEMENT_SECRET='replace-with-a-new-secret' ./rotate-management-key.sh
```

The key must contain at least 16 safe ASCII characters. Do not put the key directly in a command argument.

Use `--no-restart` to change the file without a container restart. CLIProxyAPI can load the changed configuration automatically.

## Service commands

```sh
# Show the service state.
docker compose ps

# Follow the service log.
docker compose logs -f cli-api-proxy

# Restart the service after a manual configuration change.
docker compose restart cli-api-proxy

# Same restart from any working directory.
./restart.sh

# Stop and remove the container. Local data remains present.
docker compose down
```

## Update

1. Change `CLI_PROXY_VERSION` in `.env` to a published CLIProxyAPI release.
2. Run `./install.sh`.

Re-running the one-line bootstrap gives the same result: it refreshes the
project files and re-runs `install.sh` from the install directory (default: `~/.local/share/cli-api-proxy`).

The build fails if the release has no matching archive or checksum.

## Network security

The Compose file binds all ports to `127.0.0.1` by default. Thus, other computers cannot connect directly.

CAUTION: Set `BIND_ADDRESS=0.0.0.0` only on a protected host. This value exposes the API and OAuth callback ports on all interfaces.

The application treats Docker host traffic as remote traffic. Therefore, `remote-management.allow-remote` is `true` in the generated configuration.

The management API still requires its password. Proxy routes require a client API key only when keys are configured.

On SELinux-enforcing hosts (Fedora, RHEL, Fedora CoreOS), the Compose mounts carry the `:z` suffix. Docker relabels those directories so the container can read and write them; on hosts without SELinux the suffix is ignored.

## Release source

The default version is `7.2.121`. The image downloads release files from `router-for-me/CLIProxyAPI` and checks `checksums.txt` before extraction.
