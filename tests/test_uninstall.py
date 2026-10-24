"""Check uninstall.sh behavior with no containers involved: files are
removed, user data is kept unless --purge is set, and git checkouts are
protected.
"""

import os


def stub_docker(tmp_path) -> str:
    """Return a PATH value whose docker is a no-op stub.

    Script branches that call docker then run against the stub instead of
    the host daemon, so a real container can never be touched.
    """
    stub_bin = tmp_path / "stub-bin"
    stub_bin.mkdir()
    docker = stub_bin / "docker"
    docker.write_text("#!/bin/sh\nexit 0\n")
    docker.chmod(0o755)
    return f"{stub_bin}{os.pathsep}{os.environ['PATH']}"


def test_default_uninstall_keeps_user_data(stage, xdg, run_sh):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)
    run_sh("./uninstall.sh", cwd=copy, env=xdg.env)

    # Auth tokens and settings live in the XDG directories; the default
    # uninstall keeps them.
    assert (xdg.conf / "config.yaml").is_file()
    assert (xdg.data / "auths").is_dir()
    assert (xdg.state / "logs").is_dir()


def test_purge_removes_user_data(stage, xdg, run_sh):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)
    run_sh("./uninstall.sh", "--purge", cwd=copy, env=xdg.env)

    assert not xdg.conf.exists()
    assert not xdg.data.exists()
    assert not xdg.state.exists()


def test_git_checkout_is_protected(stage, xdg, run_sh, tmp_path):
    # A .git entry marks a source checkout. Run in a staged copy with one:
    # if the guard ever regresses, the test can only delete the throwaway
    # copy and the sentinels, and the stub docker keeps uninstall.sh away
    # from the host daemon.
    copy = stage()
    (copy / ".git").mkdir()
    sentinels = [xdg.conf / "config.yaml", xdg.data / "auths" / "token.txt"]
    for path in sentinels:
        path.parent.mkdir(parents=True)
        path.write_text("keep\n")

    result = run_sh(
        "./uninstall.sh",
        "--purge",
        cwd=copy,
        env={**xdg.env, "PATH": stub_docker(tmp_path)},
        check=False,
    )

    assert result.returncode != 0
    assert "git checkout" in result.stderr
    assert (copy / "uninstall.sh").is_file()
    assert all(path.is_file() for path in sentinels)


def test_bootstrap_uninstall_fallback_reports_kept_paths(repo, xdg, run_sh, tmp_path):
    # No installed files exist, so bootstrap reports which XDG directories
    # it kept. The stub docker keeps the fallback from contacting the host
    # daemon, so a real container named cli-api-proxy is never removed.
    result = run_sh(
        "bootstrap.sh",
        "--uninstall",
        cwd=repo,
        env={
            **xdg.env,
            "CLI_PROXY_HOME": str(xdg.data_home / "gone"),
            "PATH": stub_docker(tmp_path),
        },
        check=False,
    )
    assert result.returncode == 0
    assert "Kept" in result.stderr
