from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_install_sh_clones_public_staging() -> None:
    text = (ROOT / "install.sh").read_text()
    assert "https://github.com/derEremit/yabridge-staging" in text
    assert "yabridge-test-infra" not in text
    assert "yabridge-staging-main" in text
