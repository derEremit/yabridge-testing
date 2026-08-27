from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WF = ROOT / ".github" / "workflows"


def test_public_workflows_exclude_the_website() -> None:
    names = {p.name for p in WF.glob("*.yml")}
    assert names == {
        "test-harness.yml",
        "probe.yml",
        "ansible.yml",
        "build-images.yml",
    }
    assert not (WF / "web.yml").exists()
    for path in WF.glob("*.yml"):
        assert "web/" not in path.read_text()
