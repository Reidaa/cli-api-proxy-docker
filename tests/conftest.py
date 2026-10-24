"""Shared fixtures for the script tests.

Each test runs the real shell scripts (bootstrap.sh, install.sh,
uninstall.sh) inside a throwaway copy of the tree, with throwaway XDG
directories. pytest removes both after the test, so generated files never
land in the real checkout or in the real user directories.
"""

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

# .git must not be copied: its presence would make uninstall.sh treat the
# copy as a protected git checkout. .venv is large, and generated files from
# a developer's checkout (an existing .env on its own records real paths)
# must not seed the staged copy.
STAGE_IGNORE = shutil.ignore_patterns(
    ".git",
    ".venv",
    ".env",
    "config.yaml",
    "config.yaml.backup.*",
    "credentials.txt",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
)


@dataclass(frozen=True)
class XdgDirs:
    """The three XDG base directories, as the install scripts resolve them."""

    config_home: Path
    data_home: Path
    state_home: Path

    @property
    def conf(self) -> Path:
        """$XDG_CONFIG_HOME/cli-api-proxy"""
        return self.config_home / "cli-api-proxy"

    @property
    def data(self) -> Path:
        """$XDG_DATA_HOME/cli-api-proxy"""
        return self.data_home / "cli-api-proxy"

    @property
    def state(self) -> Path:
        """$XDG_STATE_HOME/cli-api-proxy"""
        return self.state_home / "cli-api-proxy"

    @property
    def env(self) -> dict[str, str]:
        """XDG_* variables that point the scripts at these directories."""
        return {
            "XDG_CONFIG_HOME": str(self.config_home),
            "XDG_DATA_HOME": str(self.data_home),
            "XDG_STATE_HOME": str(self.state_home),
        }


@pytest.fixture(scope="session")
def repo() -> Path:
    """The project root, one level above tests/."""
    return Path(__file__).resolve().parent.parent


@pytest.fixture
def stage(tmp_path: Path, repo: Path):
    """Factory: return a fresh throwaway copy of the project tree.

    install.sh and uninstall.sh must run from an installed copy, never from
    the real checkout, because they create and delete files beside the
    scripts (.env, and the whole directory on uninstall).
    """

    made: list[Path] = []

    def _stage() -> Path:
        dest = tmp_path / f"copy-{len(made)}"
        made.append(dest)
        shutil.copytree(repo, dest, ignore=STAGE_IGNORE)
        return dest

    return _stage


@pytest.fixture
def xdg(tmp_path: Path) -> XdgDirs:
    """Three throwaway XDG base directories, so tests never touch real ones."""

    dirs = XdgDirs(
        config_home=tmp_path / "xdg-config",
        data_home=tmp_path / "xdg-data",
        state_home=tmp_path / "xdg-state",
    )
    for base in (dirs.config_home, dirs.data_home, dirs.state_home):
        base.mkdir()
    return dirs


@pytest.fixture
def run_sh():
    """Run a repo script with sh, capture output, fail the test on errors.

    Pass check=False to inspect a non-zero exit code yourself.
    """

    def _run(script, *args, cwd, env=None, check=True):
        full_env = os.environ.copy()
        if env:
            full_env.update(env)
        return subprocess.run(
            ["sh", str(script), *args],
            cwd=str(cwd),
            env=full_env,
            check=check,
            capture_output=True,
            text=True,
        )

    return _run
