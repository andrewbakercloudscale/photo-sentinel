"""Adding an S3 bucket from the app: the keys go into the rclone config, never onto
a command line, and the account is kept only when a test file proves the bucket
can be written to and reports MD5."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from iphone_image import storage
from iphone_image.cloud import RcloneProvider
from iphone_image.storage import AddS3Error, add_s3, alias_backend, resolve_aliases

SECRET = "wJalr/K7MDENG+bPxRfi,CY:EXAMPLE"


class FakeRclone:
    """rclone as add_s3 sees it: a config file, listremotes, and a bucket."""

    def __init__(self, conf: Path, *, writes=True, md5=True, existing="gdrive: drive\n"):
        self.conf = conf
        self.writes = writes
        self.md5 = md5
        self.existing = existing
        self.calls: list[list[str]] = []
        self.deleted = False

    def __call__(self, args, capture_output=True, text=True, timeout=None, check=False, input=None):
        self.calls.append(list(args))
        cmd = args[1]
        out, code, err = "", 0, ""
        if cmd == "config" and args[2] == "file":
            out = f"Configuration file is stored at:\n{self.conf}\n"
        elif cmd == "config" and args[2] == "show":
            out = _section(self.conf, args[3])
        elif cmd == "listremotes":
            out = self.existing
        elif cmd == "rcat":
            code, err = (0, "") if self.writes else (1, "AccessDenied: Access Denied")
        elif cmd == "lsjson":
            row = {"Path": storage.S3_PROBE, "Hashes": {"md5": "ab" * 16} if self.md5 else {}}
            out = json.dumps([row])
        elif cmd == "deletefile":
            self.deleted = True
        return subprocess.CompletedProcess(args, code, out, err)


def _section(conf: Path, name: str) -> str:
    lines, inside = [], False
    for line in conf.read_text().splitlines():
        if line.startswith("["):
            inside = line == f"[{name}]"
        elif inside:
            lines.append(line)
    return "\n".join(lines)


def test_adds_an_alias_rooted_at_the_bucket(tmp_path: Path) -> None:
    conf = tmp_path / "rclone.conf"
    conf.write_text("[gdrive]\ntype = drive\n")
    fake = FakeRclone(conf)
    done = add_s3("photos", "my-bucket/iphone", "AKIAEXAMPLE", SECRET, "eu-west-1", run=fake)
    assert done["remote"] == "photos" and done["bucket"] == "my-bucket/iphone"
    text = conf.read_text()
    assert text.startswith("[gdrive]\ntype = drive\n"), "the existing account is untouched"
    assert "[photos]\ntype = alias\nremote = :s3,provider=AWS," in text
    assert text.rstrip().endswith(":my-bucket/iphone")
    assert conf.stat().st_mode & 0o777 == 0o600
    assert fake.deleted, "the test file is removed again"
    assert not any(SECRET in " ".join(c) for c in fake.calls), (
        "the secret never goes on a command line"
    )


def test_a_bucket_that_refuses_writes_leaves_the_config_as_it_was(tmp_path: Path) -> None:
    conf = tmp_path / "rclone.conf"
    conf.write_text("[gdrive]\ntype = drive\n")
    with pytest.raises(AddS3Error, match=r"Access Denied.*Nothing was added"):
        add_s3("photos", "b", "AKIA", SECRET, run=FakeRclone(conf, writes=False))
    assert conf.read_text() == "[gdrive]\ntype = drive\n"


def test_no_md5_means_no_account(tmp_path: Path) -> None:
    conf = tmp_path / "rclone.conf"
    with pytest.raises(AddS3Error, match="MD5"):
        add_s3("photos", "b", "AKIA", SECRET, run=FakeRclone(conf, md5=False))
    assert not conf.exists(), "a config file that did not exist before is not left behind"


@pytest.mark.parametrize(
    ("name", "bucket", "key", "secret", "why"),
    [
        ("gdrive", "b", "k", "s", "already an account"),
        ("bad name", "b", "k", "s", "letters, digits"),
        ("photos", "", "k", "s", "bucket name is empty"),
        ("photos", "b", "", "s", "access key"),
    ],
)
def test_refuses_bad_input_without_writing(tmp_path, name, bucket, key, secret, why) -> None:
    conf = tmp_path / "rclone.conf"
    conf.write_text("[gdrive]\ntype = drive\n")
    with pytest.raises(AddS3Error, match=why):
        add_s3(name, bucket, key, secret, run=FakeRclone(conf))
    assert conf.read_text() == "[gdrive]\ntype = drive\n"


def test_an_encrypted_config_is_not_touched(tmp_path: Path) -> None:
    conf = tmp_path / "rclone.conf"
    conf.write_text("RCLONE_ENCRYPT_V0:\nabc\n")
    with pytest.raises(AddS3Error, match="encrypted"):
        add_s3("photos", "b", "k", "s", run=FakeRclone(conf))
    assert conf.read_text() == "RCLONE_ENCRYPT_V0:\nabc\n"


def test_an_endpoint_makes_it_s3_compatible(tmp_path: Path) -> None:
    target = storage.s3_target("b", "k", "s", "auto", "https://x.r2.cloudflarestorage.com")
    assert target.startswith(":s3,provider=Other,")
    assert 'endpoint="https://x.r2.cloudflarestorage.com"' in target


def test_an_alias_is_listed_as_the_backend_it_points_at(tmp_path: Path) -> None:
    conf = tmp_path / "rclone.conf"
    conf.write_text(
        "[gdrive]\ntype = drive\n\n[photos]\ntype = alias\nremote = :s3,provider=AWS:b\n"
        "\n[sub]\ntype = alias\nremote = gdrive:Photos\n"
    )
    found = [
        storage.Account("gdrive", "drive"),
        storage.Account("photos", "alias"),
        storage.Account("sub", "alias"),
    ]
    kinds = {a.name: a.kind for a in resolve_aliases(found, run=FakeRclone(conf))}
    assert kinds == {"gdrive": "drive", "photos": "s3", "sub": "drive"}
    assert alias_backend("nowhere", {}) is None


def test_the_backup_engine_checks_an_s3_alias_by_md5(tmp_path: Path) -> None:
    conf = tmp_path / "rclone.conf"
    conf.write_text("[photos]\ntype = alias\nremote = :s3,provider=AWS:b\n")
    script = tmp_path / "rclone"
    script.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = listremotes ]; then echo "photos: alias"; exit 0; fi\n'
        'if [ "$1" = config ]; then echo "type = alias"; echo "remote = :s3,provider=AWS:b"; fi\n'
    )
    script.chmod(0o755)
    provider = RcloneProvider("photos", binary=str(script))
    provider.check()
    assert provider.hash_name == "md5"


@pytest.mark.skipif(shutil.which("rclone") is None, reason="rclone not installed")
def test_real_rclone_reads_the_quoting(tmp_path: Path) -> None:
    """The quoting is rclone's: a value with a comma, a colon and a quote survives it.
    Checked offline with the local backend, which parses connection strings the same way."""
    (tmp_path / "bucket").mkdir()
    (tmp_path / "bucket" / "a.txt").write_text("hi")
    value = storage._quoted('x,y:z"q')
    conf = tmp_path / "rclone.conf"
    conf.write_text(
        f"[photos]\ntype = alias\nremote = :local,description={value}:{tmp_path}/bucket\n"
    )
    run = lambda *a: subprocess.run(  # noqa: E731
        ["rclone", "--config", str(conf), *a], capture_output=True, text=True, timeout=30
    )
    listed = run("lsjson", "--hash", "photos:")
    assert listed.returncode == 0, listed.stderr
    rows = json.loads(listed.stdout)
    assert [r["Path"] for r in rows] == ["a.txt"]
    assert rows[0]["Hashes"]["md5"] == "49f68a5c8493ec2c0bf489821c21fc3b"
