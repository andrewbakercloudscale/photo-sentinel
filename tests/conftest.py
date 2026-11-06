from __future__ import annotations

import atexit
import os
import shutil
import sys
import tempfile
from pathlib import Path

import pytest

# Tests never touch the real home folder. Commands run without --config fall back to
# ~/.photo-sentinel, and a test that wrote there once created a near-empty state folder
# that the app then preferred over the real one. HOME is replaced before iphone_image is
# imported, because config.STATE_DIR is worked out at import time; subprocesses inherit it.
_TEST_HOME = tempfile.mkdtemp(prefix="photo-sentinel-test-home-")
os.environ["HOME"] = _TEST_HOME
atexit.register(shutil.rmtree, _TEST_HOME, ignore_errors=True)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from iphone_image.config import Config
from iphone_image.db.database import Database


@pytest.fixture
def db(tmp_path: Path) -> Database:
    database = Database(tmp_path / "test.sqlite").connect()
    database.migrate()
    yield database
    database.close()


@pytest.fixture
def config_file(tmp_path: Path) -> Path:
    """A config that keeps every artefact inside tmp_path."""
    path = tmp_path / "config.yaml"
    path.write_text(
        "version: 1\n"
        f'archive: {{local_path: "{tmp_path}/archive"}}\n'
        f'database: {{path: "{tmp_path}/db.sqlite"}}\n'
        f'logging: {{level: info, path: "{tmp_path}/logs"}}\n'
        f'recycle_bin: {{enabled: true, path: "{tmp_path}/recycle", '
        "retention: 90d, use_macos_trash: true}\n"
    )
    return path


@pytest.fixture
def config(config_file: Path) -> Config:
    from iphone_image.config import load_config

    return load_config(config_file)
