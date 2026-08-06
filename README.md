# CLIProxyAPI container

This project builds and runs [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) in a Docker container.

The image downloads a versioned release and checks its SHA-256 checksum. It supports Linux AMD64 and ARM64 hosts.

## Requirements

Install these components:

- Docker Engine or Docker Desktop
- Docker Compose v2
- A POSIX shell

## Install

Run the installer:

```sh
./install.sh
```

The installer does these actions:

1. It creates a local configuration.
2. It creates a management password.
3. It builds the container image.
4. It starts the service.

The installer stores the generated management password in `config/credentials.txt`. This file has permission mode `600`.

Open these URLs:

- API: <http://127.0.0.1:8317>
- Management UI: <http://127.0.0.1:8317/management.html>

Use the management UI to add provider credentials or start an OAuth login.

## Connect a client

The default configuration does not create a client API key. To require client authentication, add one or more keys to `api-keys` in `config/config.yaml`.

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
| `config/config.yaml` | The CLIProxyAPI configuration |
| `config/credentials.txt` | The generated management password |
| `data/auths/` | OAuth tokens and provider credentials |
| `data/logs/` | File logs, if file logging is active |
| `data/plugins/` | Optional dynamic plugins |
| `data/static/` | The downloaded management panel |

Edit `config/config.yaml` to add advanced provider configuration. The management UI can also change this file and creates temporary validation files in `config/` while saving.

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

The script generates a new key and saves it in `config/credentials.txt`. It also restarts a running container.

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

# Stop and remove the container. Local data remains present.
docker compose down
```

## Update

1. Change `CLI_PROXY_VERSION` in `.env` to a published CLIProxyAPI release.
2. Run `./install.sh`.

The build fails if the release has no matching archive or checksum.

## Network security

The Compose file binds all ports to `127.0.0.1` by default. Thus, other computers cannot connect directly.

CAUTION: Set `BIND_ADDRESS=0.0.0.0` only on a protected host. This value exposes the API and OAuth callback ports on all interfaces.

The application treats Docker host traffic as remote traffic. Therefore, `remote-management.allow-remote` is `true` in the generated configuration.

The management API still requires its password. Proxy routes require a client API key only when keys are configured.

## Release source

The default version is `7.2.121`. The image downloads release files from `router-for-me/CLIProxyAPI` and checks `checksums.txt` before extraction.
