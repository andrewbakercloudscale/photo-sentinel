"""Backing up the motion half of Live Photos.

A Live Photo is two files on the phone: the still and a short `.MOV`. The
backup has only ever copied the still, so removal refuses every Live Photo
(SAFETY section 6: a group with an unverified member is not removable), and
632 of them sat on the phone for that reason alone.

This copies the motion half of every Live Photo whose still is already verified
in the cloud, next to the still and under the same name with `.MOV`, the way the
phone itself pairs them. Each one goes through a staging folder on the Mac, is
hashed there, uploaded, and recorded only once the remote's own listing returns
the same hash. The staged copy is deleted as soon as it is verified, so the Mac
never holds more than one batch.

What is recorded is an `asset_resources` row (LIVE_PHOTO_VIDEO, cloud verified)
and a `cloud_objects` row carrying the remote path and the remote's hash.
Removal reads both and lists the remote again before anything leaves the phone.
"""

from __future__ import annotations

import shutil
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

from .cloud import (
    CloudError,
    CloudProvider,
    RcloneProvider,
    hash_name_of,
    split_cloud_path,
)
from .config import Config
from .db.database import Database, utcnow
from .digests import file_digests
from .journal import Journal, Op
from .logs import get_logger
from .photos.helper import Helper

log = get_logger("live")

MOTION = "LIVE_PHOTO_VIDEO"

#: Staged, uploaded and listed together. A motion half is a few MB, so a batch
#: is a few hundred MB of disk at most and one folder listing to verify it.
BATCH = 50

#: The same rule sync and cloud use: this many failures in a row is an outage.
CONSECUTIVE_FAILURE_LIMIT = 5


@dataclass
class Motion:
    """One Live Photo whose motion half is not yet in the cloud."""

    asset_id: int
    local_identifier: str
    still: str  # the still's recorded cloud path
    destination: str = ""
    relative: str = ""  # the motion half's path under `destination`


@dataclass
class LiveResult:
    planned: int = 0
    copied: int = 0
    verified: int = 0
    failed: int = 0
    bytes: int = 0
    stopped_early: str = ""
    failures: list[dict[str, Any]] = field(default_factory=list)


def missing(db: Database) -> list[dict[str, Any]]:
    """Live Photos on the phone, still verified in the cloud, motion half not."""
    rows = db.conn.execute(
        "SELECT a.id, a.device_asset_id, a.cloud_path FROM assets a "
        "WHERE a.subtypes LIKE '%\"live\"%' AND a.present_on_phone = 1 "
        "AND a.cloud_status = 'CLOUD_VERIFIED' AND a.cloud_path IS NOT NULL "
        "AND a.cloud_path != '' AND a.device_asset_id IS NOT NULL "
        "AND NOT EXISTS (SELECT 1 FROM asset_resources r WHERE r.asset_id = a.id "
        f"  AND r.resource_type = '{MOTION}' AND r.cloud_status = 'CLOUD_VERIFIED') "
        "ORDER BY a.created_at_device"
    ).fetchall()
    return [dict(r) for r in rows]


def motion_path(still: str) -> str:
    """Where a still's motion half goes: beside it, same name, `.MOV`."""
    return str(PurePosixPath(still).with_suffix(".MOV"))


def plan(config: Config, db: Database, *, limit: int = 0) -> list[Motion]:
    """What would be copied, and where. Nothing is fetched or uploaded."""
    work: list[Motion] = []
    taken = {
        str(r[0])
        for r in db.conn.execute("SELECT cloud_path FROM assets WHERE cloud_path IS NOT NULL")
    }
    for row in missing(db):
        still = str(row["cloud_path"])
        destination, relative = split_cloud_path(config, still)
        target = motion_path(relative)
        if f"{destination}/{target}" in taken:
            # Another asset's file already sits at that name, a real video
            # called IMG_1234.MOV. Never overwrite it: a suffix keeps both.
            target = str(PurePosixPath(target).with_name(PurePosixPath(target).stem + "_live.MOV"))
        work.append(
            Motion(
                asset_id=int(row["id"]),
                local_identifier=str(row["device_asset_id"]),
                still=still,
                destination=destination,
                relative=target,
            )
        )
        if limit and len(work) >= limit:
            break
    return work


def staging(config: Config) -> Path:
    return config.archive.local_path / ".live-staging"


def run(
    config: Config,
    db: Database,
    *,
    limit: int = 0,
    helper: Helper | None = None,
    provider: CloudProvider | None = None,
    on_progress: Callable[[str], None] | None = None,
) -> LiveResult:
    """Copy, upload and verify each motion half. Nothing on the phone is touched."""
    if not config.cloud.enabled or not config.cloud.remote:
        raise CloudError("no cloud remote is set up, so there is nowhere to copy to.")

    def note(line: str) -> None:
        log.info("%s", line)
        if on_progress:
            on_progress(line)

    helper = helper or Helper()
    helper.check()
    provider = provider or RcloneProvider(
        config.cloud.remote,
        transfers=config.performance.cloud_upload_workers,
        batch_timeout=config.cloud.batch_timeout_seconds,
        stall_timeout=config.cloud.stall_timeout_seconds,
        no_progress_timeout=config.cloud.no_progress_timeout_seconds,
        tps_limit=config.cloud.tps_limit,
    )
    provider.check()
    hash_name = hash_name_of(provider)

    result = LiveResult()
    work = plan(config, db, limit=limit)
    result.planned = len(work)
    if not work:
        return result

    root = staging(config)
    # Whatever a killed run left behind is not evidence of anything.
    shutil.rmtree(root, ignore_errors=True)

    # One batch per remote folder, so verifying it lists that folder alone.
    folders: dict[tuple[str, str], list[Motion]] = {}
    for motion in work:
        key = (motion.destination, str(PurePosixPath(motion.relative).parent))
        folders.setdefault(key, []).append(motion)
    batches = [
        (destination, folder, group[i : i + BATCH])
        for (destination, folder), group in folders.items()
        for i in range(0, len(group), BATCH)
    ]

    journal = Journal(db)
    failures_in_a_row = 0
    with journal.operation(
        Op.CLOUD_UPLOAD, command="live-photos", detail={"planned": len(work)}
    ) as operation:
        for number, (destination, folder, group) in enumerate(batches, start=1):
            note(f"[{number}/{len(batches)}] {folder}: {len(group)} motion half(s)")
            staged: dict[int, tuple[Path, str, str, int]] = {}
            exports = [(m.local_identifier, root / m.destination / m.relative) for m in group]
            for record in helper.export(exports, motion=True):
                if record.get("event") != "exported":
                    continue
                item = next(
                    (m for m in group if m.local_identifier == record.get("localIdentifier")),
                    None,
                )
                if item is None:
                    continue
                if record.get("error"):
                    result.failed += 1
                    result.failures.append({"file": item.relative, "error": record["error"]})
                    continue
                path = root / item.destination / item.relative
                sha, md5 = file_digests(path)
                size = path.stat().st_size
                staged[item.asset_id] = (path, sha, md5, size)
                result.copied += 1
                result.bytes += size

            if not staged:
                failures_in_a_row += 1
            else:
                ready = [m for m in group if m.asset_id in staged]
                try:
                    provider.upload(root / destination, [m.relative for m in ready], destination)
                    remote = provider.hashes(destination, None if folder == "." else folder)
                except CloudError as exc:
                    failures_in_a_row += 1
                    result.failed += len(ready)
                    result.failures.append({"file": folder, "error": str(exc)})
                    note(f"  upload failed: {exc}")
                else:
                    failures_in_a_row = 0
                    for motion in ready:
                        path, sha, md5, size = staged[motion.asset_id]
                        expected = md5 if hash_name == "md5" else sha
                        found = remote.get(motion.relative)
                        if not found or found != expected:
                            result.failed += 1
                            result.failures.append(
                                {
                                    "file": motion.relative,
                                    "error": "not found after upload"
                                    if not found
                                    else "the remote's hash does not match the copy",
                                }
                            )
                            continue
                        _record(db, config, motion, sha, expected, size)
                        result.verified += 1
                    note(f"  verified {result.verified:,} of {len(work):,}")
            shutil.rmtree(root, ignore_errors=True)
            operation.note(copied=result.copied, verified=result.verified, failed=result.failed)

            if failures_in_a_row >= CONSECUTIVE_FAILURE_LIMIT:
                result.stopped_early = (
                    f"stopped after {failures_in_a_row} batches failed in a row. "
                    f"{result.verified:,} are verified and kept; run it again to carry on."
                )
                note(result.stopped_early)
                break
    return result


def _record(
    db: Database, config: Config, motion: Motion, sha: str, remote_hash: str, size: int
) -> None:
    now = utcnow()
    filename = PurePosixPath(motion.relative).name
    db.conn.execute(
        "INSERT INTO asset_resources (asset_id, resource_type, required, filename, size_bytes, "
        "sha256, local_status, cloud_status, cloud_verified_at, created_at, updated_at) "
        "VALUES (?, ?, 1, ?, ?, ?, 'RELEASED', 'CLOUD_VERIFIED', ?, ?, ?) "
        "ON CONFLICT (asset_id, resource_type, filename) DO UPDATE SET "
        "size_bytes = excluded.size_bytes, sha256 = excluded.sha256, "
        "cloud_status = 'CLOUD_VERIFIED', cloud_verified_at = excluded.cloud_verified_at, "
        "updated_at = excluded.updated_at",
        (motion.asset_id, MOTION, filename, size, sha, now, now, now),
    )
    resource_id = db.conn.execute(
        "SELECT id FROM asset_resources WHERE asset_id = ? AND resource_type = ? AND filename = ?",
        (motion.asset_id, MOTION, filename),
    ).fetchone()[0]
    db.conn.execute("DELETE FROM cloud_objects WHERE resource_id = ?", (resource_id,))
    db.conn.execute(
        "INSERT INTO cloud_objects (asset_id, resource_id, provider, remote, path, size_bytes, "
        "hash, status, uploaded_at, verified_at, created_at, updated_at) "
        "VALUES (?, ?, 'rclone', ?, ?, ?, ?, 'VERIFIED', ?, ?, ?, ?)",
        (
            motion.asset_id,
            resource_id,
            config.cloud.remote,
            f"{motion.destination}/{motion.relative}",
            size,
            remote_hash,
            now,
            now,
            now,
            now,
        ),
    )


def motion_object(db: Database, asset_id: int) -> dict[str, Any] | None:
    """The verified motion half's remote path and hash, for removal to re-check."""
    row = db.conn.execute(
        "SELECT o.path, o.hash FROM asset_resources r "
        "JOIN cloud_objects o ON o.resource_id = r.id "
        f"WHERE r.asset_id = ? AND r.resource_type = '{MOTION}' "
        "AND r.cloud_status = 'CLOUD_VERIFIED' AND o.status = 'VERIFIED' "
        "ORDER BY o.id DESC LIMIT 1",
        (asset_id,),
    ).fetchone()
    return dict(row) if row else None
