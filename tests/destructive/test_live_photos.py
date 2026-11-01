# ruff: noqa: F811 -- `env` is a pytest fixture, imported so these tests can ask for it
"""Live Photos: backing up the motion half, and what removal then allows.

The motion half is the second file of a Live Photo. Removal refused every Live
Photo while only the still was backed up; these tests pin both sides: the
copy is recorded only when the remote's listing proves it, and removal takes a
Live Photo only when the remote, listed again, still holds both halves.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from test_remove_from_iphone import DEST, FakeCloud, env, on_phone, plan  # noqa: F401

from iphone_image import live

MOTION = b"motion half"
LIVE = json.dumps(["live"])


class MotionHelper:
    """Photos, faked: writes a motion half for every Live Photo it is asked for."""

    def __init__(self, *, without: set[str] | None = None) -> None:
        self.asked: list[tuple[str, Path]] = []
        self.motion: list[bool] = []
        self.without = without or set()

    def check(self) -> None:
        return None

    def export(self, work: list[tuple[str, Path]], *, motion: bool = False, **_: Any) -> Any:
        self.motion.append(motion)
        for identifier, path in work:
            self.asked.append((identifier, path))
            if identifier in self.without:
                yield {
                    "event": "exported",
                    "localIdentifier": identifier,
                    "error": "asset has no Live Photo motion half",
                }
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(MOTION)
            yield {"event": "exported", "localIdentifier": identifier, "bytes": len(MOTION)}


class UploadingCloud(FakeCloud):
    """A remote that holds what was uploaded, with its SHA-256, like Drive."""

    hash_name = "sha256"

    def __init__(self, *, corrupt: bool = False) -> None:
        super().__init__()
        self.corrupt = corrupt

    def upload(self, root: Path, relatives: list[str], destination: str) -> None:
        for relative in relatives:
            body = (root / relative).read_bytes()
            self.stored[relative] = hashlib.sha256(b"x" if self.corrupt else body).hexdigest()

    def hashes(self, destination: str, subdir: str | None = None, **_: Any) -> dict[str, str]:
        return dict(self.stored)


def motion_rows(db) -> list[dict[str, Any]]:
    return [
        dict(r)
        for r in db.conn.execute(
            "SELECT r.resource_type, r.cloud_status, o.path, o.hash FROM asset_resources r "
            "JOIN cloud_objects o ON o.resource_id = r.id"
        )
    ]


def test_it_backs_up_the_motion_half_beside_the_still(env) -> None:
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE)
    on_phone(config, db, "b", "2019/11/IMG_2.HEIC")  # not a Live Photo
    helper, cloud = MotionHelper(), UploadingCloud()

    result = live.run(config, db, helper=helper, provider=cloud)

    assert (result.planned, result.verified, result.failed) == (1, 1, 0)
    assert helper.motion == [True], "it asks Photos for the motion half, not the still"
    assert [i for i, _ in helper.asked] == ["a/L0/001"]
    assert motion_rows(db) == [
        {
            "resource_type": "LIVE_PHOTO_VIDEO",
            "cloud_status": "CLOUD_VERIFIED",
            "path": f"{DEST}/2019/11/IMG_1.MOV",
            "hash": hashlib.sha256(MOTION).hexdigest(),
        }
    ]
    assert not live.staging(config).exists(), "the Mac copy goes once it is verified"
    assert live.plan(config, db) == [], "done once is done"


def test_nothing_is_recorded_when_the_remote_hash_does_not_match(env) -> None:
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE)
    result = live.run(config, db, helper=MotionHelper(), provider=UploadingCloud(corrupt=True))
    assert (result.verified, result.failed) == (0, 1)
    assert motion_rows(db) == []


def test_a_live_photo_photos_has_no_motion_half_for_fails_and_is_not_recorded(env) -> None:
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE)
    result = live.run(
        config, db, helper=MotionHelper(without={"a/L0/001"}), provider=UploadingCloud()
    )
    assert (result.verified, result.failed) == (0, 1)
    assert motion_rows(db) == []


def test_only_live_photos_whose_still_is_backed_up_are_planned(env) -> None:
    """The motion half goes beside the still, so without a still there is no place."""
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE, cloud=False)
    assert live.plan(config, db) == []


def test_it_never_takes_a_name_another_asset_holds(env) -> None:
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE)
    on_phone(config, db, "v", "2019/11/IMG_1.MOV")  # a real video, same name
    (item,) = live.plan(config, db)
    assert item.relative == "2019/11/IMG_1_live.MOV"


def test_removal_takes_a_live_photo_once_both_halves_are_in_the_cloud(env) -> None:
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE)
    cloud = UploadingCloud()
    cloud.stored["2019/11/IMG_1.HEIC"] = hashlib.sha256(b"photo").hexdigest()
    live.run(config, db, helper=MotionHelper(), provider=cloud)

    eligible, result = plan(config, db, cloud)

    assert [c.filename for c in eligible] == ["IMG_1.HEIC"], result.blocks
    assert eligible[0].evidence["motion_hash_confirmed"] == f"{DEST}/2019/11/IMG_1.MOV"


def test_removal_refuses_when_the_motion_half_is_gone_from_the_cloud_now(env) -> None:
    """The ledger says verified; the remote, asked again, no longer has it."""
    config, db = env
    on_phone(config, db, "a", "2019/11/IMG_1.HEIC", subtypes=LIVE)
    cloud = UploadingCloud()
    live.run(config, db, helper=MotionHelper(), provider=cloud)
    now = FakeCloud({"2019/11/IMG_1.HEIC": hashlib.sha256(b"photo").hexdigest()})

    eligible, result = plan(config, db, now)

    assert eligible == []
    assert result.blocks == {"Live Photo whose motion half is not in the cloud now": 1}
