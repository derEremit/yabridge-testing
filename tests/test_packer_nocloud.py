import re
from pathlib import Path

PACKER_HTTP = Path(__file__).resolve().parents[1] / "packer" / "http"
UBUNTU = Path(__file__).resolve().parents[1] / "packer" / "ubuntu-2404-gnome.pkr.hcl"
ARCH = Path(__file__).resolve().parents[1] / "packer" / "arch-kde-plasma.pkr.hcl"
WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
USES_SHA = re.compile(r"@[0-9a-f]{40}$")


def _last_shell_block(text: str) -> str:
    parts = text.split('provisioner "shell"')
    assert len(parts) > 1
    return parts[-1]


def test_nocloud_user_data_and_meta_data_exist() -> None:
    user_data = (PACKER_HTTP / "user-data").read_text()
    meta_data = (PACKER_HTTP / "meta-data").read_text()

    assert user_data.startswith("#cloud-config")
    assert "autoinstall:" in user_data
    assert "instance-id: yabridge-ubuntu" in meta_data
    assert not (PACKER_HTTP / "preseed.cfg").exists()


def test_ubuntu_boot_command_still_uses_nocloud_net() -> None:
    text = UBUNTU.read_text()
    assert "nocloud-net" in text
    assert "http://{{ .HTTPIP }}:{{ .HTTPPort }}/" in text


def test_ubuntu_last_provisioner_locks_password_removes_nopasswd_and_powers_off() -> None:
    block = _last_shell_block(UBUNTU.read_text())
    assert "passwd -l" in block or "usermod -L" in block
    assert "/etc/sudoers.d/yabridge" in block
    assert "shutdown -P now" in block or "poweroff" in block
    assert "expect_disconnect = true" in block
    assert 'shutdown_command = "true"' in UBUNTU.read_text()
    assert "sudo -S shutdown" not in UBUNTU.read_text()


def test_arch_last_provisioner_locks_passwords_removes_nopasswd_and_powers_off() -> None:
    block = _last_shell_block(ARCH.read_text())
    assert "passwd -l" in block or "usermod -L" in block
    # Last block must delete the %wheel NOPASSWD line this template appended.
    assert "sed" in block
    assert "%wheel" in block
    assert "NOPASSWD" in block
    assert "/d" in block
    assert ">> /etc/sudoers" not in block
    assert "shutdown -P now" in block or "poweroff" in block
    assert "expect_disconnect = true" in block
    assert 'shutdown_command = "true"' in ARCH.read_text()


def test_arch_iso_is_dated_and_checksummed() -> None:
    text = ARCH.read_text()
    assert "iso/latest" not in text
    assert "iso_checksum" in text
    assert "sha256:" in text
    assert 'default = "none"' not in text


def test_qemu_plugin_version_is_exact() -> None:
    for name in ("ubuntu-2404-gnome.pkr.hcl", "arch-kde-plasma.pkr.hcl"):
        text = (Path(__file__).resolve().parents[1] / "packer" / name).read_text()
        assert 'version = ">=' not in text


def test_github_workflow_uses_are_commit_pinned() -> None:
    for path in sorted(WORKFLOWS.glob("*.yml")):
        for line in path.read_text().splitlines():
            stripped = line.strip()
            if not stripped.startswith("uses:"):
                continue
            uses = stripped.split("uses:", 1)[1].strip().split()[0]
            if uses.startswith("docker://"):
                continue
            assert USES_SHA.search(uses), f"{path.name}: {uses} is not pinned to a 40-hex SHA"
