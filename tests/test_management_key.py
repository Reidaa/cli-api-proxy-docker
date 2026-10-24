"""Key rotation must work with new installs and existing legacy configs."""

import pytest


@pytest.mark.parametrize("section", ["management", "remote-management"])
def test_rotate_management_key(stage, xdg, run_sh, section):
    copy = stage()
    run_sh("./install.sh", "--no-start", cwd=copy, env=xdg.env)
    config = xdg.conf / "config.yaml"
    config.write_text(
        f'{section}:\n  secret-key: "old-secret"\n'
        'plugins:\n  configs:\n    example:\n      secret-key: "plugin-secret"\n'
    )
    original = config.read_text()
    secret = "replacement-secret-1234"

    run_sh(
        "./rotate-management-key.sh",
        "--no-restart",
        cwd=copy,
        env={**xdg.env, "MANAGEMENT_SECRET": secret},
    )

    assert config.read_text() == original.replace("old-secret", secret)
    assert f"Management UI password: {secret}" in (
        xdg.conf / "credentials.txt"
    ).read_text()
    backups = list(xdg.conf.glob("config.yaml.backup.*"))
    assert len(backups) == 1
    assert backups[0].read_text() == original
