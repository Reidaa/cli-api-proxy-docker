"""Run compose against an installed tree and check the mounts use the XDG
directories recorded in .env. Needs the docker CLI for "compose config"; no
daemon interaction happens except through config rendering.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("docker") is None, reason="docker CLI not available"
)


def compose_config(cwd: Path) -> list[str]:
    """Render the Compose file, ignoring any exported version override.

    A CLI_PROXY_VERSION in the caller's environment takes precedence over
    .env, which would hide the default and pin behavior under test.
    """
    env = {key: value for key, value in os.environ.items() if key != "CLI_PROXY_VERSION"}
    rendered = subprocess.run(
        ["docker", "compose", "config"],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
        env=env,
    ).stdout
    return rendered.splitlines()


def test_compose_mounts_the_xdg_directories(stage, xdg, run_sh):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)

    lines = compose_config(copy)

    # The shell checks matched whole lines; compare the same exact mount
    # lines, indentation included, so a prefix match cannot pass.
    assert f"        source: {xdg.conf}" in lines
    assert "        target: /config" in lines
    assert f"        source: {xdg.data}" in lines
    assert "        target: /data" in lines
    assert f"        source: {xdg.state / 'logs'}" in lines
    assert "        target: /data/logs" in lines

    # Every bind mount must carry the :z SELinux relabel, or the container
    # cannot read its files on enforcing hosts (Fedora, RHEL, CoreOS). The
    # rendered relabel nests under the mount's target line.
    relabeled = set()
    current = None
    for line in lines:
        if line.startswith("        target: "):
            current = line.split()[1]
        elif line == "          selinux: z" and current is not None:
            relabeled.add(current)
            current = None
    for target in ("/config", "/data", "/data/logs"):
        assert target in relabeled

    # The shell negative check was a plain substring search at any
    # indentation; keep it a substring so it cannot silently miss a mount.
    assert not any("target: /config/config.yaml" in line for line in lines)


def test_compose_version_default_and_override(stage, xdg, run_sh):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)

    # Both Compose defaults (image tag, build arg) must agree, so a bump
    # cannot change one and leave the other on the old release.
    defaults = set(
        re.findall(r"CLI_PROXY_VERSION:-([^}]+)\}", (copy / "compose.yaml").read_text())
    )
    assert len(defaults) == 1, defaults
    default = defaults.pop()

    # Compare stripped lines: both keys are nested in the rendered YAML.
    lines = [line.strip() for line in compose_config(copy)]
    assert f"image: local/cli-api-proxy:{default}" in lines
    assert f"CLI_PROXY_VERSION: {default}" in lines

    # A pin in .env wins over the default for the image tag and the build arg.
    env_path = copy / ".env"
    env_path.write_text(env_path.read_text() + "CLI_PROXY_VERSION=9.9.9\n")

    lines = [line.strip() for line in compose_config(copy)]
    assert "image: local/cli-api-proxy:9.9.9" in lines
    assert "CLI_PROXY_VERSION: 9.9.9" in lines
