# Provisioning and Reproducibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Create the isolated worktree with superpowers:using-git-worktrees at execution time (submodule `yabridge-test-infra`, branch `remediate/provisioning`).

**Goal:** Make Ubuntu Packer boot via real NoCloud files, strip known passwords and passwordless sudo before the image is publishable, build yabridge with Meson + `cross-wine.conf`, and pin Packer/Actions/Arch ISO.

**Architecture:** NoCloud `user-data`/`meta-data` replace the misnamed preseed. A last root provisioner locks passwords, removes NOPASSWD, and powers off. The documented Ansible playbook becomes Meson. CI validates Packer and syntax-checks playbooks. Unused roles stay unused.

**Tech Stack:** Packer QEMU, Ubuntu autoinstall, Archinstall, Ansible, Meson, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-27-provisioning-design.md`

## Global Constraints

- No Python hash lockfiles and no Docker image digest.
- Do not `import_role` `roles/yabridge` or `roles/wine`. Do not fill their missing task files.
- Do not pin Kron4ek Wine inside Ansible.
- No Molecule, live SSH, or `packer build` on every PR.
- Do not pass `-Dbitbridge=true` unless the cloned tree's `meson_options.txt` defines `bitbridge`.
- Delete missing `include_vars`; do not add placeholder yml files.
- Do not hash a just-downloaded installer and call it a pin.
- Commit submodule changes before the parent gitlink. Nothing is pushed unless asked.
- Use `web/.venv` only for web tests if you touch web workflows; Packer/Ansible tests are static (pytest or shell) from the submodule root.

## File structure

| File | Responsibility |
|---|---|
| `yabridge-test-infra/packer/http/user-data` | Ubuntu autoinstall (moved from `preseed.cfg`) |
| `yabridge-test-infra/packer/http/meta-data` | NoCloud instance-id |
| `yabridge-test-infra/packer/http/preseed.cfg` | Deleted |
| `yabridge-test-infra/packer/ubuntu-2404-gnome.pkr.hcl` | Last provisioner strip+poweroff; `shutdown_command = "true"` |
| `yabridge-test-infra/packer/arch-kde-plasma.pkr.hcl` | Dated ISO + sha256; last provisioner strip+poweroff |
| `yabridge-test-infra/ansible/playbooks/build-yabridge.yml` | Meson + cross-wine.conf |
| `yabridge-test-infra/ansible/playbooks/provision-base.yml` | Drop missing include_vars |
| `yabridge-test-infra/docs/getting-started.md` | Meson wording; installer-digest residual risk |
| `yabridge-test-infra/.github/workflows/ansible.yml` | Syntax-check documented playbooks |
| `yabridge-test-infra/.github/workflows/*.yml` | Action SHA pins |
| `yabridge-test-infra/tests/test_packer_nocloud.py` | NoCloud + secrets-strip contracts |
| `yabridge-test-infra/tests/test_ansible_build.py` | Meson contract + syntax-check |

---

### Task 1: NoCloud user-data and meta-data

**Files:**
- Create: `yabridge-test-infra/packer/http/user-data`
- Create: `yabridge-test-infra/packer/http/meta-data`
- Delete: `yabridge-test-infra/packer/http/preseed.cfg`
- Create: `yabridge-test-infra/tests/test_packer_nocloud.py`
- Modify: none of the `.pkr.hcl` boot commands (they already point at the HTTP root)

**Interfaces:**
- Produces: NoCloud files at the Packer HTTP root
- `meta-data` contains `instance-id: yabridge-ubuntu`
- `user-data` is the former `preseed.cfg` body and starts with `#cloud-config`

- [ ] **Step 1: Write the failing NoCloud tests**

```python
# yabridge-test-infra/tests/test_packer_nocloud.py
from pathlib import Path

PACKER_HTTP = Path(__file__).resolve().parents[1] / "packer" / "http"
UBUNTU = Path(__file__).resolve().parents[1] / "packer" / "ubuntu-2404-gnome.pkr.hcl"


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
```

- [ ] **Step 2: Run the tests and witness the failure**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_packer_nocloud.py
```

Expected: `FileNotFoundError` for `user-data` / `preseed.cfg` still present.

If system `python` is 3.14 and pytest is missing, use `yabridge-test-infra/web/.venv/bin/python -m pytest` from the submodule root with `tests/` on the path, or install pytest into a tiny venv at `yabridge-test-infra/.venv`. Do not add a new web dependency.

- [ ] **Step 3: Add the NoCloud files and delete preseed.cfg**

Copy the current `preseed.cfg` body to `user-data` unchanged. Write `meta-data`:

```
instance-id: yabridge-ubuntu
```

Delete `preseed.cfg`.

- [ ] **Step 4: Re-run the NoCloud tests and `packer validate` if Packer is installed**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_packer_nocloud.py
# optional, if packer is on PATH:
cd packer && packer validate ubuntu-2404-gnome.pkr.hcl && packer validate arch-kde-plasma.pkr.hcl
```

Expected: pytest pass. Validate may fail until Task 2 changes shutdown; if so, leave validate for Task 2.

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add packer/http/user-data packer/http/meta-data packer/http/preseed.cfg tests/test_packer_nocloud.py
git commit -m "$(cat <<'EOF'
fix: serve Ubuntu autoinstall as NoCloud user-data

nocloud-net fetches user-data and meta-data. The payload lived under
a preseed name, so the HTTP root did not provide what the boot
command asked for.
EOF
)"
```

---

### Task 2: Strip publish-time secrets and power off

**Files:**
- Modify: `yabridge-test-infra/packer/ubuntu-2404-gnome.pkr.hcl`
- Modify: `yabridge-test-infra/packer/arch-kde-plasma.pkr.hcl`
- Modify: `yabridge-test-infra/tests/test_packer_nocloud.py`

**Interfaces:**
- Last provisioner on both templates: lock image-user password, remove passwordless sudo this tree added, then `shutdown -P now` / `poweroff`.
- Ubuntu `shutdown_command` becomes `"true"` (guest already powering off).
- Arch last provisioner also `passwd -l root` so the Packer `packer` root password is not on the published disk; `shutdown_command` becomes `"true"`.
- Build-time `ssh_password` variables may remain for the *running* build.

- [ ] **Step 1: Extend the failing secrets tests**

Add to `tests/test_packer_nocloud.py`:

```python
UBUNTU = Path(__file__).resolve().parents[1] / "packer" / "ubuntu-2404-gnome.pkr.hcl"
ARCH = Path(__file__).resolve().parents[1] / "packer" / "arch-kde-plasma.pkr.hcl"


def _last_shell_block(text: str) -> str:
    parts = text.split('provisioner "shell"')
    assert len(parts) > 1
    return parts[-1]


def test_ubuntu_last_provisioner_locks_password_removes_nopasswd_and_powers_off() -> None:
    block = _last_shell_block(UBUNTU.read_text())
    assert "passwd -l" in block or "usermod -L" in block
    assert "/etc/sudoers.d/yabridge" in block
    assert "shutdown -P now" in block or "poweroff" in block
    assert 'shutdown_command = "true"' in UBUNTU.read_text()
    assert "sudo -S shutdown" not in UBUNTU.read_text()


def test_arch_last_provisioner_locks_passwords_removes_nopasswd_and_powers_off() -> None:
    block = _last_shell_block(ARCH.read_text())
    assert "passwd -l" in block or "usermod -L" in block
    assert "NOPASSWD" in block  # the line that deletes it
    assert "sed" in block or "wheel" in block
    assert "shutdown -P now" in block or "poweroff" in block
    assert 'shutdown_command = "true"' in ARCH.read_text()
```

Tighten the Arch assertion when you write it: the last block must *remove* `%wheel` NOPASSWD (for example `sed -i '/NOPASSWD/d' /etc/sudoers` scoped to the line this template appended), not merely mention the string.

- [ ] **Step 2: Run and witness failure**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_packer_nocloud.py
```

Expected: last provisioner is still cache cleanup; `sudo -S shutdown` still on Ubuntu.

- [ ] **Step 3: Replace the last provisioner on both templates**

Ubuntu — replace the current cleanup `provisioner "shell"` with one that still cleans apt lists, then:

```hcl
provisioner "shell" {
  inline = [
    "sudo apt-get clean",
    "sudo rm -rf /var/lib/apt/lists/*",
    "sudo bash -c 'rm -f /etc/sudoers.d/yabridge; passwd -l yabridge; rm -rf /tmp/*; sync; shutdown -P now'"
  ]
}
```

Set `shutdown_command = "true"`.

Arch — after KDE install, last provisioner:

```hcl
provisioner "shell" {
  inline = [
    "pacman -Scc --noconfirm",
    "rm -rf /var/cache/pacman/pkg/*",
    "passwd -l ${var.ssh_username}",
    "passwd -l root",
    "sed -i '/^%wheel ALL=(ALL:ALL) NOPASSWD: ALL$/d' /etc/sudoers",
    "rm -rf /tmp/*",
    "sync",
    "poweroff"
  ]
}
```

Set `shutdown_command = "true"`. `${var.ssh_username}` is `yabridge`.

- [ ] **Step 4: Re-run the packer tests**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_packer_nocloud.py
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add packer/ubuntu-2404-gnome.pkr.hcl packer/arch-kde-plasma.pkr.hcl tests/test_packer_nocloud.py
git commit -m "$(cat <<'EOF'
fix: strip Packer login before the image powers off

The published disk kept the build password and NOPASSWD sudo.
The last provisioner now locks those accounts and removes the
drop-in, then powers off so Packer need not sudo afterward.
EOF
)"
```

---

### Task 3: Meson yabridge playbook

**Files:**
- Modify: `yabridge-test-infra/ansible/playbooks/build-yabridge.yml`
- Modify: `yabridge-test-infra/ansible/playbooks/provision-base.yml`
- Modify: `yabridge-test-infra/docs/getting-started.md`
- Create: `yabridge-test-infra/tests/test_ansible_build.py`

**Interfaces:**
- `meson setup build --buildtype=release --cross-file=cross-wine.conf` from the clone root
- `meson compile -C build` then `meson install -C build`
- No `cmake ..`
- `provision-base.yml` has no `include_vars` of a missing distro yml

- [ ] **Step 1: Write the failing contract tests**

```python
# yabridge-test-infra/tests/test_ansible_build.py
from pathlib import Path
import subprocess

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
    for name in DOCUMENTED:
        result = subprocess.run(
            ["ansible-playbook", "--syntax-check", str(PLAYBOOKS / name)],
            cwd=str(ROOT / "ansible"),
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, f"{name}: {result.stderr}"
```

Skip the syntax-check test with `pytest.importorskip` / `shutil.which` if `ansible-playbook` is not installed, and say so in the report. Prefer installing `ansible-core` in the submodule test venv.

- [ ] **Step 2: Run and witness failure**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_ansible_build.py
```

Expected: `cmake ..` still present; `include_vars` still present.

- [ ] **Step 3: Rewrite the playbook and drop the include**

In `build-yabridge.yml`:

- Debian packages: add `meson`, `ninja-build`; keep `wine64-tools`, MinGW, `pkg-config`, xcb/dbus/mesa deps; keep `cmake` as a package if you leave it, but remove the three CMake command tasks.
- Arch packages: add `meson`, `ninja`.
- Replace configure/build/install with:

```yaml
    - name: Configure yabridge with meson
      ansible.builtin.command:
        cmd: meson setup build --buildtype=release --cross-file=cross-wine.conf
        chdir: "{{ yabridge_build_dir }}"
        creates: "{{ yabridge_build_dir }}/build/meson-private"
      become: false

    - name: Build yabridge
      ansible.builtin.command:
        cmd: meson compile -C build
        chdir: "{{ yabridge_build_dir }}"
      become: false
      changed_when: true

    - name: Install yabridge
      ansible.builtin.command:
        cmd: meson install -C build
        chdir: "{{ yabridge_build_dir }}"
      changed_when: true
```

If meson install needs `--destdir` or `-Dprefix=` to honor `yabridge_install_dir`, pass
`--prefix={{ yabridge_install_dir }}` on `meson setup` (Meson flag, not CMake).

Delete the `include_vars` task from `provision-base.yml`.

In `getting-started.md`, change “Build yabridge from source” to say Meson and `cross-wine.conf`. Do not invent settings keys.

- [ ] **Step 4: Re-run the Ansible tests**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_ansible_build.py
```

Expected: pass (syntax-check skipped only if ansible-core is absent — install it if you can).

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add ansible/playbooks/build-yabridge.yml ansible/playbooks/provision-base.yml docs/getting-started.md tests/test_ansible_build.py
git commit -m "$(cat <<'EOF'
feat: build yabridge with Meson and the Wine cross file

The documented playbook still ran CMake. Upstream in this tree is
Meson-only. Drop the missing distro include_vars that never loaded.
EOF
)"
```

---

### Task 4: Pin Arch ISO, Packer, Actions, and official installer digests

**Files:**
- Modify: `yabridge-test-infra/packer/arch-kde-plasma.pkr.hcl`
- Modify: both `.pkr.hcl` `required_plugins.qemu.version`
- Modify: `.github/workflows/web.yml`, `test-harness.yml`, `probe.yml`, `build-images.yml`
- Modify: `ansible/playbooks/install-test-plugins.yml` and `install-daws.yml` only if a vendor checksum file exists
- Modify: `docs/getting-started.md` residual-risk sentence if a vendor digest is missing
- Modify: `yabridge-test-infra/tests/test_packer_nocloud.py` (Arch URL + checksum assertions)

**Interfaces:**
- Arch `iso_url` is a dated path, not `iso/latest`. `iso_checksum` is `sha256:` + 64 hex.
- Qemu plugin version is an exact `1.x.x` (pick the current stable, e.g. the latest 1.1.x that `packer init` accepts), not `>= 1.1.0`.
- Every `uses: actions/...@vN` and `hashicorp/setup-packer@main` becomes `uses: name@<40-hex>` with a `# tag: vN` comment.
- `setup-packer` `version:` is an exact Packer version, not `latest`.

Resolve Action SHAs at implementation time:

```bash
git ls-remote https://github.com/actions/checkout.git refs/tags/v4
# use the annotated-tag peel (the 40-char object the tag points at)
```

Same for `setup-python` `v5`, `upload-artifact` `v4`. For `hashicorp/setup-packer`, pin a release tag’s commit, not `main`.

Arch ISO: pick a dated directory from https://geo.mirror.pkgbuild.com/iso/ (for example `2026.08.01/archlinux-x86_64.iso` — use whatever dated folder exists when you implement). Copy the SHA-256 from that folder’s `sha256sums.txt`. Do not set checksum to a hash of a file you just downloaded without that published sums file.

- [ ] **Step 1: Write failing pin tests**

```python
def test_arch_iso_is_dated_and_checksummed() -> None:
    text = ARCH.read_text()
    assert "iso/latest" not in text
    assert 'iso_checksum' in text
    assert "sha256:" in text
    assert 'default = "none"' not in text


def test_qemu_plugin_version_is_exact() -> None:
    for name in ("ubuntu-2404-gnome.pkr.hcl", "arch-kde-plasma.pkr.hcl"):
        text = (Path(__file__).resolve().parents[1] / "packer" / name).read_text()
        assert 'version = ">=' not in text
```

Add a workflow test that every `uses:` in `.github/workflows/*.yml` matches `@[0-9a-f]{40}` or is not an action pin you own (do not fail on local `docker://`).

- [ ] **Step 2: Run and witness failure**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_packer_nocloud.py tests/test_ansible_build.py
```

- [ ] **Step 3: Apply the pins**

Edit the files. If Vital/Dexed/OB-Xd/REAPER publish no checksum file, do not add a homemade digest; add one sentence under getting-started: those installers are version-pinned by URL only.

- [ ] **Step 4: Re-run pin tests**

Expected: pass.

- [ ] **Step 5: Commit**

```bash
cd yabridge-test-infra
git add packer .github/workflows ansible/playbooks docs/getting-started.md tests
git commit -m "$(cat <<'EOF'
chore: pin Packer, Actions, and the Arch ISO

Floating latest tags and an unchecksummed Arch ISO made image CI
non-reproducible. Actions now use commit SHAs; Packer and the ISO
use exact versions.
EOF
)"
```

---

### Task 5: Ansible CI workflow and parent gitlink

**Files:**
- Create: `yabridge-test-infra/.github/workflows/ansible.yml`
- Modify: `yabridge-test-infra/.github/workflows/build-images.yml` only if Task 4 did not already pin it
- Parent gitlink after merge

**Interfaces:**
- `ansible.yml` triggers on `ansible/**` and itself
- Job: checkout (pinned SHA), setup Python (pinned), `pip install ansible-core`, `ansible-playbook --syntax-check` for the five documented playbooks
- Full `packer build` remains `workflow_dispatch` only

- [ ] **Step 1: Write a failing workflow-presence test**

```python
def test_ansible_workflow_syntax_checks_documented_playbooks() -> None:
    text = (Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ansible.yml").read_text()
    assert "ansible-playbook" in text
    assert "--syntax-check" in text
    for name in DOCUMENTED:
        assert name in text
```

Put `DOCUMENTED` in a shared module or duplicate the five names. Do not invent playbooks.

- [ ] **Step 2: Run and witness FileNotFoundError**

- [ ] **Step 3: Add `ansible.yml` with pinned actions (same SHAs as Task 4)**

- [ ] **Step 4: Re-run tests**

```bash
cd yabridge-test-infra
python -m pytest -q tests/test_packer_nocloud.py tests/test_ansible_build.py
```

Expected: all pass.

- [ ] **Step 5: Commit in the submodule, then verify, then stop for finishing-a-development-branch**

```bash
cd yabridge-test-infra
git add .github/workflows/ansible.yml tests
git commit -m "$(cat <<'EOF'
ci: syntax-check the documented Ansible playbooks

Packer already validates on path. Ansible had no workflow, so a
broken playbook could merge unseen.
EOF
)"
```

Do not merge to `main` or update the parent gitlink in this task. The controller uses finishing-a-development-branch after the whole-branch review.

---

## Self-review

| Spec item | Task |
|---|---|
| NoCloud user-data/meta-data; delete preseed.cfg | 1 |
| Strip passwords + NOPASSWD; provisioner powers off | 2 |
| Meson + cross-wine.conf; drop missing include_vars | 3 |
| Arch ISO, Packer, Actions pins; official installer digests only | 4 |
| ansible.yml; packer validate stays; no parent `.github/` | 5 |
| No lockfiles, Docker digest, unused roles, Molecule | Global constraints |
