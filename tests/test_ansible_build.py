from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
PLAYBOOKS = ROOT / "ansible" / "playbooks"
DOCUMENTED = [
    "provision-base.yml",
    "install-wine.yml",
    "build-yabridge.yml",
    "install-daws.yml",
    "install-test-plugins.yml",
]


def test_build_yabridge_uses_meson_cross_file() -> None:
    text = (PLAYBOOKS / "build-yabridge.yml").read_text()
    assert "meson setup" in text
    assert "--cross-file=cross-wine.conf" in text
    assert "meson compile" in text
    assert "cmake .." not in text


def test_provision_base_does_not_include_missing_distro_vars() -> None:
    text = (PLAYBOOKS / "provision-base.yml").read_text()
    assert "include_vars" not in text


def test_documented_playbooks_syntax_check() -> None:
    if shutil.which("ansible-playbook") is None:
        pytest.skip("ansible-playbook not installed")
    for name in DOCUMENTED:
        result = subprocess.run(
            ["ansible-playbook", "--syntax-check", str(PLAYBOOKS / name)],
            cwd=str(ROOT / "ansible"),
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"{name}: {result.stderr}"


def test_ansible_workflow_syntax_checks_documented_playbooks() -> None:
    text = (Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ansible.yml").read_text()
    assert "ansible-playbook" in text
    assert "--syntax-check" in text
    assert "ansible-galaxy collection install" in text
    assert "community.general" in text
    for name in DOCUMENTED:
        assert name in text
