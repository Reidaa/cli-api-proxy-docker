"""Check the update-in-place behavior of bootstrap.sh.

Re-running bootstrap.sh on a host with an existing install must refresh the
project files, drop stale or smuggled ones, and keep the generated state:
.env with the resolved XDG paths, the container-owned auths/plugins/static/
logs trees, and the legacy data/config trees. Tarball installs go through a
scratch staging directory; git checkouts (including worktrees, whose .git
is a file) are updated with git alone.
"""

import os
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest


def stub_docker(tmp_path: Path) -> str:
    """Return a PATH value whose docker is a no-op stub.

    The dependency check in bootstrap.sh passes against the stub, and the
    --no-start runs seeded here never touch a real daemon either.
    """
    stub_bin = tmp_path / "stub-bin"
    stub_bin.mkdir()
    docker = stub_bin / "docker"
    docker.write_text("#!/bin/sh\nexit 0\n")
    docker.chmod(0o755)
    return f"{stub_bin}{os.pathsep}{os.environ['PATH']}"


def make_fake_install(tree: Path, marker: str) -> None:
    """Write an install.sh that echoes its arguments with a marker."""
    install = tree / "install.sh"
    install.write_text(f'#!/bin/sh\necho FAKEDINSTALL {marker} "$@"\n')
    install.chmod(0o755)


def make_tarball(
    tmp_path: Path, marker: str,
    *, smuggle: bool = False, include_readme: bool = False,
) -> Path:
    """Build a fake project tarball, wrapped in a top directory.

    tarfile keeps a directory symlink as a link and does not descend into
    it, matching what bootstrap.sh must survive. Upstream deletes are
    simulated by a tarball without README.md; smuggle=True additionally
    carries generated files (at the root, inside config/ and data/, and as
    a symlinked data dir), to check that the staging prune strips or keeps
    them safely.
    """
    pkg = tmp_path / f"src-{marker}" / "pkg"
    pkg.mkdir(parents=True)
    (pkg / "data").mkdir()
    (pkg / "config").mkdir()
    make_fake_install(pkg, marker)
    (pkg / "compose.yaml").write_text("compose\n")
    (pkg / "data" / ".gitkeep").write_text("keep\n")
    (pkg / "config" / "config.yaml.example").write_text("example\n")
    if include_readme:
        (pkg / "README.md").write_text("readme\n")
    if smuggle:
        (pkg / ".env").write_text("EVIL-ENV\n")
        (pkg / "auths").mkdir()
        (pkg / "auths" / "evil.txt").write_text("evil\n")
        (pkg / "config" / "config.yaml").write_text("evil\n")
        (pkg / "config" / "credentials.txt").write_text("evil\n")
        (pkg / "data" / "config.yaml").write_text("evil\n")
        (pkg / "config.yaml").write_text("evil\n")
        (pkg / "credentials.txt").write_text("evil\n")
        (pkg / "config.yaml.backup.20240101").write_text("evil\n")
        victim = tmp_path / "victim"
        victim.mkdir()
        (victim / "canary.txt").write_text("canary\n")
        shutil.rmtree(pkg / "data")
        (pkg / "data").symlink_to(victim)

    out = tmp_path / f"{marker}.tar.gz"
    with tarfile.open(out, "w:gz") as tar:
        tar.add(pkg, arcname="pkg")
    return out


def seed_install(dst: Path) -> None:
    """Mimic an installed tree: project files plus generated state."""
    for leaf in ("install.sh", "README.md", "compose.yaml"):
        (dst / leaf).write_text("old\n")
    (dst / "install.sh").chmod(0o755)
    (dst / ".env").write_text("BIND_ADDRESS=100.78.109.50\n")
    for name in ("auths", "logs", "plugins", "static", "data", "config"):
        (dst / name).mkdir()
    (dst / "auths" / "google.txt").write_text("token\n")
    (dst / "logs" / "run.log").write_text("line\n")
    (dst / "data" / "config.yaml").write_text("legacy\n")
    (dst / "config" / "config.yaml").write_text("secret\n")


def run_bootstrap(repo: Path, tmp_path: Path, *args: str):
    """Run bootstrap.sh with a stubbed docker on PATH."""
    return subprocess.run(
        ["/bin/sh", str(repo / "bootstrap.sh"), *args],
        env={**os.environ, "PATH": stub_docker(tmp_path)},
        capture_output=True,
        text=True,
        cwd=str(tmp_path),
        check=False,
    )


@pytest.fixture
def installed(tmp_path: Path) -> Path:
    """A seeded install directory."""
    dest = tmp_path / "installed"
    dest.mkdir()
    seed_install(dest)
    return dest


def assert_generated_state_survives(dest: Path) -> None:
    """The .env and the container-owned trees survived unchanged."""
    assert "BIND_ADDRESS=100.78.109.50" in (dest / ".env").read_text()
    assert (dest / "auths" / "google.txt").read_text() == "token\n"
    assert (dest / "logs" / "run.log").is_file()
    assert (dest / "data" / "config.yaml").read_text() == "legacy\n"
    assert (dest / "config" / "config.yaml").read_text() == "secret\n"


@pytest.fixture
def git_author() -> dict[str, str]:
    """Environment variables that make git commits deterministic."""
    return {
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    }


@pytest.fixture
def origin_and_seed(tmp_path: Path, git_author: dict[str, str]):
    """A bare remote with upstream main already at one commit.

    The fixture yields remote and seed repo paths plus a hand-off to land
    the next upstream commit (with marker text) from the seed's files.
    """
    remote = tmp_path / "remote.git"
    seed = tmp_path / "seedrepo"
    subprocess.run(
        ["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
    subprocess.run(["git", "init", "-q", "-b", "main", str(seed)], check=True)
    subprocess.run(
        ["git", "-C", str(seed), "remote", "add", "origin", str(remote)],
        check=True)

    def dig(marker: str) -> None:
        """Seed a project tree with marker and push it as the next commit."""
        make_fake_install(seed, marker)
        (seed / "compose.yaml").write_text("compose\n")
        subprocess.run(["git", "-C", str(seed), "add", "-A"], check=True)
        subprocess.run(
            ["git", "-C", str(seed), "commit", "-qm", f"update {marker}"],
            env={**os.environ, **git_author}, check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(seed), "push", "-q", "origin", "main"],
            check=True)

    dig("GITV1")
    return remote, seed, dig


def test_tarball_update_keeps_generated_state(
    repo: Path, installed: Path, tmp_path: Path
) -> None:
    result = run_bootstrap(
        repo, tmp_path, "--dir", str(installed),
        "--archive", str(make_tarball(tmp_path, "NEW")), "--no-start",
    )
    assert result.returncode == 0, result.stderr
    assert "FAKEDINSTALL NEW --no-start" in result.stdout

    # Tracked files are refreshed and stale ones removed; generated state
    # survives the update.
    assert "NEW" in (installed / "install.sh").read_text()
    assert not (installed / "README.md").exists()
    assert_generated_state_survives(installed)
    assert (installed / "config" / "config.yaml.example").read_text() == "example\n"


def test_missing_archive_fails_without_touching_the_install(
    repo: Path, installed: Path, tmp_path: Path
) -> None:
    result = run_bootstrap(
        repo, tmp_path, "--dir", str(installed),
        "--archive", str(tmp_path / "absent.tar.gz"), "--no-start",
    )
    assert result.returncode != 0
    assert "Archive not found" in result.stderr
    assert_generated_state_survives(installed)
    assert (installed / "install.sh").read_text() == "old\n"


def test_corrupt_archive_fails_before_the_update(
    repo: Path, installed: Path, tmp_path: Path
) -> None:
    broken = tmp_path / "broken.tar.gz"
    broken.write_text("not a gzip")
    result = run_bootstrap(
        repo, tmp_path, "--dir", str(installed),
        "--archive", str(broken), "--no-start",
    )
    assert result.returncode != 0
    assert_generated_state_survives(installed)
    assert (installed / "install.sh").read_text() == "old\n"


def test_archive_without_install_sh_is_refused(
    repo: Path, installed: Path, tmp_path: Path
) -> None:
    flat = tmp_path / "flat.tar.gz"
    stub = tmp_path / "root"
    stub.mkdir()
    make_fake_install(stub, "ORPHAN")
    with tarfile.open(flat, "w:gz") as tar:
        tar.add(stub / "install.sh", arcname="install.sh")
    result = run_bootstrap(
        repo, tmp_path, "--dir", str(installed),
        "--archive", str(flat), "--no-start",
    )
    assert result.returncode != 0
    assert "install.sh" in result.stderr
    assert_generated_state_survives(installed)


def test_archive_cannot_smuggle_generated_state(
    repo: Path, installed: Path, tmp_path: Path
) -> None:
    result = run_bootstrap(
        repo, tmp_path, "--dir", str(installed),
        "--archive", str(make_tarball(tmp_path, "EVIL", smuggle=True)),
        "--no-start",
    )
    assert result.returncode == 0, result.stderr
    assert "FAKEDINSTALL EVIL --no-start" in result.stdout
    assert_generated_state_survives(installed)

    # Nothing smuggled gets in, and the symlinked victim tree is untouched.
    victim = tmp_path / "victim"
    assert not (installed / "auths" / "evil.txt").exists()
    assert (victim / "canary.txt").read_text() == "canary\n"
    assert not (installed / "data").is_symlink()


def test_clone_updates_with_git_alone(
    repo: Path, tmp_path: Path, origin_and_seed
) -> None:
    # Two commits land upstream; the clone sits at v1 and bootstrap must
    # move it to v2 without any download.
    remote, _seed, dig = origin_and_seed
    clone = tmp_path / "clone"
    subprocess.run(["git", "clone", "-q", str(remote), str(clone)], check=True)
    (clone / ".env").write_text("BIND_ADDRESS=127.0.0.1\n")
    (clone / "auths").mkdir()
    (clone / "auths" / "g.txt").write_text("token\n")

    dig("GITV2")
    result = run_bootstrap(repo, tmp_path, "--dir", str(clone), "--no-start")
    assert result.returncode == 0, result.stderr
    assert "FAKEDINSTALL GITV2 --no-start" in result.stdout
    assert "GITV2" in (clone / "install.sh").read_text()
    assert "BIND_ADDRESS=127.0.0.1" in (clone / ".env").read_text()
    assert (clone / "auths" / "g.txt").read_text() == "token\n"


def test_linked_worktree_updates_and_keeps_its_gitfile(
    repo: Path, tmp_path: Path, origin_and_seed
) -> None:
    # Worktrees carry .git as a file; the update must neither delete nor
    # overwrite it.
    remote, _seed, dig = origin_and_seed
    clone = tmp_path / "clone"
    subprocess.run(["git", "clone", "-q", str(remote), str(clone)], check=True)
    (clone / ".env").write_text("BIND_ADDRESS=127.0.0.1\n")
    (clone / "auths").mkdir()
    (clone / "auths" / "g.txt").write_text("token\n")

    dig("GITV2")
    worktree = tmp_path / "wtree"
    subprocess.run(
        ["git", "-C", str(clone), "worktree", "add", "--detach", str(worktree)],
        check=True)
    assert (worktree / ".git").is_file()

    result = run_bootstrap(repo, tmp_path, "--dir", str(worktree), "--no-start")
    assert result.returncode == 0, result.stderr
    assert "FAKEDINSTALL GITV2 --no-start" in result.stdout
    assert "GITV2" in (worktree / "install.sh").read_text()
    assert (worktree / ".git").is_file()
    assert "BIND_ADDRESS=127.0.0.1" in (clone / ".env").read_text()
    assert (clone / "auths" / "g.txt").read_text() == "token\n"
