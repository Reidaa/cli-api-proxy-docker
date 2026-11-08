"""Check the cli-api-proxy command.

install runs install.sh and uninstall runs uninstall.sh. update pins a
CLIProxyAPI release in .env and rebuilds the container through install.sh.
Some tests call the command through a symlink in the throwaway bin
directory, the same way a user calls it from PATH. Stub docker and curl
keep every test away from the daemon and the network.
"""

import os
from pathlib import Path


def stub_docker(tmp_path: Path) -> str:
    """Return a PATH value whose docker is a no-op stub."""
    stub_bin = tmp_path / "stub-bin"
    stub_bin.mkdir()
    docker = stub_bin / "docker"
    docker.write_text("#!/bin/sh\nexit 0\n")
    docker.chmod(0o755)
    return f"{stub_bin}{os.pathsep}{os.environ['PATH']}"


def link_cli(copy: Path, bin_home: Path) -> Path:
    """Link the staged command into bin_home and return the link."""
    bin_home.mkdir(exist_ok=True)
    link = bin_home / "cli-api-proxy"
    link.symlink_to(copy / "cli-api-proxy")
    return link


def test_help_lists_the_commands(stage, run_sh):
    result = run_sh("cli-api-proxy", "--help", cwd=stage())
    for command in ("install", "update", "uninstall"):
        assert command in result.stdout


def test_unknown_command_exits_2(stage, run_sh):
    result = run_sh("cli-api-proxy", "bogus", cwd=stage(), check=False)
    assert result.returncode == 2
    assert "Unknown command" in result.stderr


def test_install_through_the_link_configures_the_install_dir(
    stage, xdg, run_sh, tmp_path
):
    copy = stage()
    link = link_cli(copy, xdg.bin_home)
    run_sh(link, "install", "--no-start", cwd=tmp_path, env=xdg.env)

    assert (copy / ".env").is_file()
    assert (xdg.conf / "config.yaml").is_file()


def stub_tools(
    tmp_path: Path, *, docker_up_fails: bool = False, running: str | None = None
) -> dict[str, str]:
    """Return env values with stub docker and curl first on PATH.

    docker appends its arguments to docker.log and any CLI_PROXY_VERSION it
    inherits to env.log. "docker inspect" answers with the image of a
    container running `running`, or fails when no container runs. curl
    answers like the GitHub "latest release" API with tag v9.1.0.
    """
    stub_bin = tmp_path / "stub-bin"
    stub_bin.mkdir()
    log = tmp_path / "docker.log"
    env_log = tmp_path / "env.log"
    fail = 'case "$*" in *up*) exit 1 ;; esac\n' if docker_up_fails else ""
    inspect = (
        f'case "$1" in inspect) echo "local/cli-api-proxy:{running}"; exit 0 ;; esac\n'
        if running
        else 'case "$1" in inspect) exit 1 ;; esac\n'
    )
    (stub_bin / "docker").write_text(
        "#!/bin/sh\n"
        f'echo "$*" >> "{log}"\n'
        f'[ -z "${{CLI_PROXY_VERSION+x}}" ] || echo "CLI_PROXY_VERSION=$CLI_PROXY_VERSION" >> "{env_log}"\n'
        f"{inspect}{fail}exit 0\n"
    )
    (stub_bin / "curl").write_text(
        '#!/bin/sh\nprintf \'{\\n  "tag_name": "v9.1.0",\\n}\\n\'\n'
    )
    for tool in ("docker", "curl"):
        (stub_bin / tool).chmod(0o755)
    return {"PATH": f"{stub_bin}{os.pathsep}{os.environ['PATH']}"}


def env_version(copy: Path) -> list[str]:
    """The CLI_PROXY_VERSION lines of the install's .env."""
    lines = (copy / ".env").read_text().splitlines()
    return [line for line in lines if line.startswith("CLI_PROXY_VERSION=")]


def test_update_pins_the_latest_release_and_rebuilds(stage, xdg, run_sh, tmp_path):
    copy = stage()
    link = link_cli(copy, xdg.bin_home)
    run_sh(link, "install", "--no-start", cwd=tmp_path, env=xdg.env)

    run_sh(link, "update", cwd=tmp_path, env={**xdg.env, **stub_tools(tmp_path)})

    assert env_version(copy) == ["CLI_PROXY_VERSION=9.1.0"]
    assert "compose up --detach --build" in (tmp_path / "docker.log").read_text()


def test_update_to_a_given_version_replaces_the_pin(stage, xdg, run_sh, tmp_path):
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=xdg.env)
    with (copy / ".env").open("a") as env:
        env.write("CLI_PROXY_VERSION=1.0.0\n")

    run_sh(
        "cli-api-proxy",
        "update",
        "--version",
        "v9.2.0",
        cwd=copy,
        env={**xdg.env, **stub_tools(tmp_path)},
    )

    assert env_version(copy) == ["CLI_PROXY_VERSION=9.2.0"]


def test_update_at_the_latest_version_does_nothing(stage, xdg, run_sh, tmp_path):
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=xdg.env)

    result = run_sh(
        "cli-api-proxy",
        "update",
        cwd=copy,
        env={**xdg.env, **stub_tools(tmp_path, running="9.1.0")},
    )

    assert "already" in result.stdout
    assert "compose up" not in (tmp_path / "docker.log").read_text()


def test_update_compares_with_the_running_container_not_the_pin(
    stage, xdg, run_sh, tmp_path
):
    """A pin in .env that the container never got must still trigger a rebuild."""
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=xdg.env)
    with (copy / ".env").open("a") as env:
        env.write("CLI_PROXY_VERSION=9.1.0\n")

    run_sh(
        "cli-api-proxy",
        "update",
        "--version",
        "9.1.0",
        cwd=copy,
        env={**xdg.env, **stub_tools(tmp_path, running="1.0.0")},
    )

    assert env_version(copy) == ["CLI_PROXY_VERSION=9.1.0"]
    assert "compose up --detach --build" in (tmp_path / "docker.log").read_text()


def test_update_unsets_an_exported_version_before_the_rebuild(
    stage, xdg, run_sh, tmp_path
):
    """Compose prefers a shell variable over .env, so update must drop it."""
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=xdg.env)

    run_sh(
        "cli-api-proxy",
        "update",
        cwd=copy,
        env={**xdg.env, **stub_tools(tmp_path), "CLI_PROXY_VERSION": "1.0.0"},
    )

    assert env_version(copy) == ["CLI_PROXY_VERSION=9.1.0"]
    assert "compose up --detach --build" in (tmp_path / "docker.log").read_text()
    assert not (tmp_path / "env.log").exists()


def test_failed_update_restores_the_previous_pin(stage, xdg, run_sh, tmp_path):
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=xdg.env)
    before = (copy / ".env").read_text()

    result = run_sh(
        "cli-api-proxy",
        "update",
        cwd=copy,
        env={**xdg.env, **stub_tools(tmp_path, docker_up_fails=True)},
        check=False,
    )

    assert result.returncode == 1
    assert (copy / ".env").read_text() == before


def test_update_needs_an_install(stage, xdg, run_sh, tmp_path):
    result = run_sh(
        "cli-api-proxy",
        "update",
        cwd=stage(),
        env={**xdg.env, **stub_tools(tmp_path)},
        check=False,
    )
    assert result.returncode == 1
    assert "install" in result.stderr


def test_update_rejects_an_invalid_version(stage, xdg, run_sh, tmp_path):
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=xdg.env)
    result = run_sh(
        "cli-api-proxy",
        "update",
        "--version",
        "1.0;rm",
        cwd=copy,
        env={**xdg.env, **stub_tools(tmp_path)},
        check=False,
    )
    assert result.returncode == 2


def test_uninstall_removes_the_install_dir_and_the_link(stage, xdg, run_sh, tmp_path):
    copy = stage()
    link = link_cli(copy, xdg.bin_home)
    run_sh(
        link,
        "uninstall",
        cwd=tmp_path,
        env={**xdg.env, "PATH": stub_docker(tmp_path)},
    )

    assert not copy.exists()
    assert not link.is_symlink()
