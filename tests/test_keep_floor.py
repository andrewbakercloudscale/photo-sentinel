"""The last 30 days always stay on the phone, whatever any age or filter asks.

The per-type ages above it are chosen on the app's My phone page (2026-11-11),
which replaced a blanket two-year floor.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from pydantic import ValidationError

from iphone_image.config import Config
from iphone_image.remove import _too_recent

NOW = datetime(2026, 11, 9, 12, 0, tzinfo=UTC)


def _config(tmp_path: Path, **remove) -> Config:
    return Config(
        archive={"local_path": str(tmp_path / "archive")},
        database={"path": str(tmp_path / "db.sqlite")},
        logging={"path": str(tmp_path / "logs")},
        photos={"library_path": str(tmp_path / "lib.photoslibrary")},
        remove_from_iphone=remove,
    )


def _taken(days_ago: int) -> dict:
    return {"created_at_device": (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")}


def test_the_floor_is_30_days_by_default(tmp_path: Path) -> None:
    assert _config(tmp_path).remove_from_iphone.keep_newer_than == timedelta(days=30)


def test_anything_under_30_days_is_kept(tmp_path: Path) -> None:
    config = _config(tmp_path)
    for days in (0, 1, 15, 29):
        assert _too_recent(config, _taken(days), NOW), days


def test_anything_over_30_days_may_go(tmp_path: Path) -> None:
    config = _config(tmp_path)
    assert _too_recent(config, _taken(31), NOW) is None
    assert _too_recent(config, _taken(180), NOW) is None
    assert _too_recent(config, _taken(3650), NOW) is None


def test_the_floor_cannot_be_lowered(tmp_path: Path) -> None:
    with pytest.raises(ValidationError, match="cannot be below 30 days"):
        _config(tmp_path, keep_newer_than="7d")


def test_the_floor_can_be_raised(tmp_path: Path) -> None:
    config = _config(tmp_path, keep_newer_than="3y")
    assert _too_recent(config, _taken(900), NOW)
    assert _too_recent(config, _taken(1200), NOW) is None


def test_never_keeps_everything(tmp_path: Path) -> None:
    config = _config(tmp_path, keep_newer_than="never")
    assert _too_recent(config, _taken(5000), NOW)


def test_an_asset_without_a_date_is_kept(tmp_path: Path) -> None:
    config = _config(tmp_path)
    assert _too_recent(config, {"created_at_device": None}, NOW)
    assert _too_recent(config, {"created_at_device": "garbage"}, NOW)
