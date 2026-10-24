"""Run install.sh without Docker and check where it writes things. Generates
no containers and needs only the scripts present in the working tree.
"""

import stat
from pathlib import Path


def mode_of(path: Path) -> int:
    """The permission bits of a path, as an octal value like 0o600."""
    return stat.S_IMODE(path.stat().st_mode)


def test_install_writes_to_xdg_dirs(stage, xdg, run_sh):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)

    # Generated configuration lives in the XDG config directory, not the
    # project directory.
    assert (xdg.conf / "config.yaml").is_file()
    assert (xdg.conf / "credentials.txt").is_file()
    assert mode_of(xdg.conf / "config.yaml") == 0o600
    assert mode_of(xdg.conf / "credentials.txt") == 0o600
    assert mode_of(xdg.conf) == 0o700

    config_text = (xdg.conf / "config.yaml").read_text()
    assert "__MANAGEMENT_SECRET__" not in config_text
    assert 'secret-key: "' in config_text

    # Data goes to XDG data, logs to XDG state.
    for sub in ("auths", "plugins", "static"):
        assert (xdg.data / sub).is_dir()
    assert (xdg.state / "logs").is_dir()
    assert mode_of(xdg.data) == 0o700
    assert mode_of(xdg.state / "logs") == 0o700

    assert not (copy / "config" / "config.yaml").exists()
    assert not (copy / "data" / "auths").exists()

    # .env stays beside compose.yaml but records the resolved XDG paths, so
    # Compose works even when the XDG variables are not set at runtime.
    assert mode_of(copy / ".env") == 0o600
    env_lines = (copy / ".env").read_text().splitlines()
    assert f"CLI_PROXY_CONFIG_DIR={xdg.conf}" in env_lines
    assert f"CLI_PROXY_DATA_DIR={xdg.data}" in env_lines
    assert f"CLI_PROXY_STATE_DIR={xdg.state}" in env_lines


def test_legacy_layout_migrates_to_xdg(stage, xdg, run_sh):
    copy = stage()

    # A pre-XDG install kept config/ and data/ beside the project scripts.
    # Those directories already exist in the staged copy (the repo ships the
    # config template there), so create them like mkdir -p would.
    legacy_conf = copy / "config"
    legacy_conf.mkdir(parents=True, exist_ok=True)
    (legacy_conf / "config.yaml").write_text('secret-key: "legacy"\n')
    legacy_auths = copy / "data" / "auths"
    legacy_auths.mkdir(parents=True, exist_ok=True)
    (legacy_auths / "legacy-token.txt").write_text("x\n")
    legacy_logs = copy / "data" / "logs"
    legacy_logs.mkdir(parents=True, exist_ok=True)
    (legacy_logs / "legacy.log").write_text("old log\n")

    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)

    # The old files move out of the project directory into the XDG dirs.
    assert not (legacy_conf / "config.yaml").exists()
    assert 'secret-key: "legacy"' in (xdg.conf / "config.yaml").read_text()
    assert (xdg.data / "auths" / "legacy-token.txt").is_file()
    assert (xdg.state / "logs" / "legacy.log").is_file()
