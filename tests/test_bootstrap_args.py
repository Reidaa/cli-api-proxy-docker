"""Check the argument and dependency handling of bootstrap.sh before any
download happens. No network access and no Docker work is needed for these
cases.
"""

import os
import subprocess


def test_help_lists_the_options(repo, run_sh):
    result = run_sh("bootstrap.sh", "--help", cwd=repo, check=False)
    assert result.returncode == 0
    assert "--dir" in result.stdout


def test_unknown_option_fails_with_usage(repo, run_sh):
    result = run_sh("bootstrap.sh", "--bogus", cwd=repo, check=False)
    # bootstrap.sh documents "Unknown options exit 2 with usage"; assert
    # that contract exactly.
    assert result.returncode == 2
    assert "Unknown option" in result.stderr


def test_missing_docker_stops_before_download(repo, tmp_path):
    # An empty bin directory hides docker and compose, so the dependency
    # check takes its "missing Docker" path. /bin/sh must be absolute: the
    # overridden PATH cannot resolve any program, including sh itself.
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    env = {**os.environ, "PATH": str(empty_bin)}
    result = subprocess.run(
        ["/bin/sh", str(repo / "bootstrap.sh")],
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "get.docker.com" in result.stderr
