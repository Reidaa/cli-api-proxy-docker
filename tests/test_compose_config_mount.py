"""Run compose against an installed tree and check the mounts use the XDG
directories recorded in .env. Needs the docker CLI for "compose config"; no
daemon interaction happens except through config rendering.
"""

import shutil
import subprocess

import pytest

pytestmark = pytest.mark.skipif(
    shutil.which("docker") is None, reason="docker CLI not available"
)


def test_compose_mounts_the_xdg_directories(stage, xdg, run_sh):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)

    rendered = subprocess.run(
        ["docker", "compose", "config"],
        cwd=copy,
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    lines = rendered.splitlines()

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
    assert "target: /config/config.yaml" not in rendered
