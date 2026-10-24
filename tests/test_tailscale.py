"""Check the --tailscale option: address resolution, the .env updates, and
the Compose port rendering. No real Tailscale or Docker daemon is needed
beyond "docker compose config" rendering.
"""

import os
import shutil
import subprocess

import pytest


def make_stubs(tmp_path, **scripts) -> str:
    """Write executable sh stubs and return a PATH with them first."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name, body in scripts.items():
        path = bin_dir / name
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)
    return f"{bin_dir}{os.pathsep}{os.environ['PATH']}"


def test_install_help_documents_the_option(repo, run_sh):
    result = run_sh("install.sh", "--help", cwd=repo, check=False)
    assert "--tailscale" in result.stdout


def test_missing_tailscale_points_to_setup(stage, xdg, run_sh, tmp_path):
    # Both tools exist but fail, so no Tailscale address can be found.
    env = {**xdg.env, "PATH": make_stubs(tmp_path, tailscale="exit 1", ip="exit 1")}
    copy = stage()
    result = run_sh(
        "install.sh", "--no-start", "--tailscale", cwd=copy, env=env, check=False
    )
    assert result.returncode != 0
    assert "tailscale up" in result.stdout + result.stderr


def test_tailscale_address_lands_in_env(stage, xdg, run_sh, tmp_path):
    env = {**xdg.env, "PATH": make_stubs(tmp_path, tailscale="echo 100.64.0.1")}
    copy = stage()
    run_sh("install.sh", "--no-start", "--tailscale", cwd=copy, env=env)
    assert "BIND_ADDRESS=100.64.0.1" in (copy / ".env").read_text().splitlines()


def test_default_stays_on_loopback(stage, xdg, run_sh, tmp_path):
    env = {**xdg.env, "PATH": make_stubs(tmp_path, tailscale="echo 100.64.0.1")}
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env=env)
    assert "BIND_ADDRESS=127.0.0.1" in (copy / ".env").read_text().splitlines()


def test_rerun_updates_existing_env(stage, xdg, run_sh, tmp_path):
    copy = stage()
    first = make_stubs(tmp_path, tailscale="echo 100.64.0.1")
    run_sh("install.sh", "--no-start", cwd=copy, env={**xdg.env, "PATH": first})
    assert "BIND_ADDRESS=127.0.0.1" in (copy / ".env").read_text().splitlines()

    second = make_stubs(tmp_path, tailscale="echo 100.64.0.2")
    run_sh(
        "install.sh", "--no-start", "--tailscale", cwd=copy, env={**xdg.env, "PATH": second}
    )
    assert "BIND_ADDRESS=100.64.0.2" in (copy / ".env").read_text().splitlines()


def test_address_outside_cgnat_is_rejected(stage, xdg, run_sh, tmp_path):
    env = {**xdg.env, "PATH": make_stubs(tmp_path, tailscale="echo 192.168.1.5")}
    copy = stage()
    result = run_sh(
        "install.sh", "--no-start", "--tailscale", cwd=copy, env=env, check=False
    )
    assert result.returncode != 0


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker CLI not available")
def test_ports_bind_to_the_tailscale_address(stage, xdg, run_sh, tmp_path):
    stubs = make_stubs(tmp_path, tailscale="echo 100.64.0.1")
    copy = stage()
    run_sh("install.sh", "--no-start", cwd=copy, env={**xdg.env, "PATH": stubs})
    run_sh(
        "install.sh", "--no-start", "--tailscale", cwd=copy, env={**xdg.env, "PATH": stubs}
    )

    rendered = subprocess.run(
        ["docker", "compose", "config"],
        cwd=copy,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert rendered.count("host_ip: 100.64.0.1") == 6
    assert "host_ip: 127.0.0.1" not in rendered
