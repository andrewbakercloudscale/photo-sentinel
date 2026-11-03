"""The installer exists in two places that must never drift apart.

install.sh is what scripts/publish-installer.sh puts in S3; the README carries the same
script inside a one-paste ``cat > ... <<'EOF'`` block. A fix made in one and not the
other would mean the README and the download install different things.
"""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALL = ROOT / "install.sh"
README = ROOT / "README.md"


def _readme_block() -> str:
    text = README.read_text()
    m = re.search(
        r"cat > /tmp/install-photo-sentinel\.sh <<'EOF'\n(.*?)\nEOF\n"
        r"chmod \+x /tmp/install-photo-sentinel\.sh && exec /tmp/install-photo-sentinel\.sh",
        text,
        re.S,
    )
    assert m, "README one-paste installer block not found"
    return m.group(1) + "\n"


def test_readme_paste_block_matches_install_sh() -> None:
    assert _readme_block() == INSTALL.read_text()


def test_install_sh_is_valid_bash() -> None:
    subprocess.run(["bash", "-n", str(INSTALL)], check=True)


def test_install_sh_pins_the_python_the_project_needs() -> None:
    body = INSTALL.read_text()
    assert "brew install python@3.14" in body
    assert 'brew --prefix python@3.14)/bin/python3.14" -m venv' in body
    assert ">=3.12" in (ROOT / "pyproject.toml").read_text()


def test_readme_names_the_public_download() -> None:
    url = "https://andrewninjawordpress.s3.af-south-1.amazonaws.com/photo-sentinel-install.sh"
    assert url in README.read_text()
    assert url.rsplit("/", 1)[1] in (ROOT / "scripts/publish-installer.sh").read_text()
