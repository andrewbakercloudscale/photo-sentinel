"""Where backups go: the rclone account, and the archive folder on this Mac.

Accounts live in the user's rclone config; this tool only names one. An account
can hold backups only if it reports each file's SHA-256, because that hash is
the evidence removal from the phone rests on. Google Drive does. S3 reports MD5
(and not even that for multipart uploads), OneDrive and Dropbox their own
hashes, so those are listed but cannot be chosen until verification learns
their hash.
"""

from __future__ import annotations

import contextlib
import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

#: rclone backend types whose listings carry a hash the ledger also records, and
#: which one. Drive and a local folder report SHA-256; S3 reports only MD5 (its
#: ETag, which rclone also stores as metadata on multipart uploads so large files
#: keep one). A type missing here cannot verify, so nothing is ever released or
#: removed against it.
HASH_TYPES = {"drive": "sha256", "local": "sha256", "s3": "md5"}


def hash_for(kind: str) -> str | None:
    """The ledger column whose value this backend's listing can be checked against."""
    return HASH_TYPES.get(kind)


KIND_TITLES = {
    "drive": "Google Drive",
    "s3": "S3 compatible",
    "onedrive": "OneDrive",
    "dropbox": "Dropbox",
    "box": "Box",
    "b2": "Backblaze B2",
    "local": "A folder on this Mac",
    "google photos": "Google Photos",
    "googlephotos": "Google Photos",
    "gphotos": "Google Photos",
}

#: rclone's Google Photos backend, by every name rclone accepts for it (its name,
#: file name and prefix). Never in HASH_TYPES: Google Photos re-encodes what it is
#: sent and reports no hash, so it can hold an extra copy but never a backup.
GOOGLE_PHOTOS_KINDS = frozenset({"google photos", "googlephotos", "gphotos"})


def is_google_photos(kind: str) -> bool:
    return kind.strip().lower() in GOOGLE_PHOTOS_KINDS


@dataclass(frozen=True)
class Account:
    name: str
    kind: str

    @property
    def title(self) -> str:
        return KIND_TITLES.get(self.kind, self.kind)

    @property
    def can_verify(self) -> bool:
        return self.kind in HASH_TYPES

    def as_dict(self) -> dict[str, object]:
        return {
            "name": self.name,
            "kind": self.kind,
            "title": self.title,
            "canVerify": self.can_verify,
        }


def parse_remotes(text: str) -> list[Account]:
    """`rclone listremotes --long`: one `name: type` per line."""
    found = []
    for line in text.splitlines():
        name, sep, kind = line.partition(":")
        if sep and name.strip():
            found.append(Account(name.strip(), kind.strip()))
    return found


def accounts(binary: str = "rclone", run=subprocess.run) -> list[Account]:
    try:
        out = run(
            [binary, "listremotes", "--long"],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return resolve_aliases(parse_remotes(out), binary, run)


def alias_backend(target: str, kinds: dict[str, str]) -> str | None:
    """The backend an alias points at: `:s3,provider=AWS,...:bucket` is s3, and
    `other:folder` is whatever `other` is. None when it cannot be told."""
    if target.startswith(":"):
        head = target[1:].split(",", 1)[0].split(":", 1)[0].strip()
        return head or None
    name, sep, _ = target.partition(":")
    return kinds.get(name.strip()) if sep else None


def resolve_aliases(
    found: list[Account], binary: str = "rclone", run=subprocess.run
) -> list[Account]:
    """An alias reports as `alias`; it is listed as the backend it points at, whose
    hashes its listings carry. An "Add S3 account" bucket is such an alias."""
    kinds = {a.name: a.kind for a in found}
    resolved = []
    for a in found:
        if a.kind == "alias":
            target = (_config_show(a.name, binary, run) or {}).get("remote", "")
            backend = alias_backend(target, kinds)
            if backend and backend != "alias":
                a = Account(a.name, backend)
        resolved.append(a)
    return resolved


def shared_client_id(remote: str, binary: str = "rclone") -> bool | None:
    """True when a Google Drive remote has no client_id of its own. It then signs
    in through rclone's one shared Google project, whose quota every rclone user
    draws on, and Drive answers with rateLimitExceeded. None when unknown."""
    try:
        out = subprocess.run(
            [binary, "config", "show", remote],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return parse_shared_client_id(out)


def parse_shared_client_id(text: str) -> bool:
    """`rclone config show <remote>`: `key = value` lines."""
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() == "client_id" and value.strip():
            return False
    return True


def drive_folder_url(remote: str, folder: str, binary: str = "rclone") -> str | None:
    """The Google Drive web page of `folder` in `remote`, or None when it cannot be found.

    Drive addresses folders by id, not path, so the parent is listed for the folder's id.
    """
    path = PurePosixPath(folder.strip("/"))
    if not path.name:
        return "https://drive.google.com/drive/my-drive"
    parent = "" if str(path.parent) == "." else str(path.parent)
    try:
        out = subprocess.run(
            [binary, "lsjson", "--dirs-only", f"{remote.rstrip(':')}:{parent}"],
            capture_output=True,
            text=True,
            timeout=60,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return parse_folder_url(out, path.name)


def parse_folder_url(listing: str, name: str) -> str | None:
    """`rclone lsjson --dirs-only` of a Drive folder: the page of its child `name`."""
    try:
        entries = json.loads(listing)
    except ValueError:
        return None
    for e in entries if isinstance(entries, list) else []:
        if e.get("IsDir") and e.get("Name") == name and e.get("ID"):
            return f"https://drive.google.com/drive/folders/{e['ID']}"
    return None


def archive_problem(path: Path) -> str | None:
    """Why `path` cannot be the archive folder, or None."""
    if path.exists() and not path.is_dir():
        return f"{path} is a file, not a folder"
    probe = path if path.exists() else next((p for p in path.parents if p.exists()), None)
    if probe is None or not probe.is_dir():
        return f"no part of {path} exists"
    if not os.access(probe, os.W_OK):
        return f"{probe} cannot be written to"
    return None


class OwnClientError(Exception):
    """Why signing in with the owner's own Google client did not go ahead. The
    rclone account is left as it was."""


#: How long the browser sign-in may take before it is given up.
AUTHORIZE_SECONDS = 600


def own_client(
    remote: str,
    client_id: str,
    client_secret: str,
    destination: str,
    binary: str = "rclone",
    run=subprocess.run,
) -> dict[str, object]:
    """Point a Google Drive account at the owner's own Google Cloud client, so it
    stops sharing rclone's throttled one.

    The new sign-in is tried on the side first (`rclone authorize`, in the
    browser) and checked to reach the same Google Drive: the same top-level
    folders, by id. Only then is the account changed, after a copy of the rclone
    config is kept, and the change is checked again; if that check fails the copy
    is put back. Refused while any rclone runs: a running upload would write its
    old sign-in back over the new one when it refreshes it.
    """
    client_id, client_secret = client_id.strip(), client_secret.strip()
    if not client_id.endswith(".apps.googleusercontent.com"):
        raise OwnClientError(
            "that is not a client ID: it ends in .apps.googleusercontent.com. "
            "Copy it from the client you made in Google Cloud."
        )
    if not client_secret:
        raise OwnClientError("the client secret is empty. Copy it from the same client.")
    name = remote.rstrip(":")
    settings = _config_show(name, binary, run)
    if settings is None or settings.get("type") != "drive":
        raise OwnClientError(f"{name} is not a Google Drive account in rclone.")
    _refuse_while_rclone_runs(binary, run)

    before = _top_folders(f"{name}:", binary, run)
    token = _authorize(client_id, client_secret, binary, run)
    trial = {
        "RCLONE_CONFIG_IIMOWNCLIENT_TYPE": "drive",
        "RCLONE_CONFIG_IIMOWNCLIENT_CLIENT_ID": client_id,
        "RCLONE_CONFIG_IIMOWNCLIENT_CLIENT_SECRET": client_secret,
        "RCLONE_CONFIG_IIMOWNCLIENT_TOKEN": token,
        "RCLONE_CONFIG_IIMOWNCLIENT_SCOPE": settings.get("scope") or "drive",
    }
    after = _top_folders("iimownclient:", binary, run, env=trial)
    if after is None:
        raise OwnClientError(
            "signed in, but Google Drive could not be read with it. Check the Google Drive API "
            "is turned on in that Google Cloud project, then try again."
        )
    _same_drive(before, after, destination)

    _refuse_while_rclone_runs(binary, run)
    conf = _config_file(binary, run)
    kept = conf.with_name(conf.name + ".before-own-client")
    kept.write_bytes(conf.read_bytes())
    kept.chmod(0o600)
    changed = run(
        [
            binary,
            "config",
            "update",
            name,
            "client_id",
            client_id,
            "client_secret",
            client_secret,
            "token",
            token,
            "config_refresh_token",
            "false",
            "--non-interactive",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    now = _config_show(name, binary, run) or {}
    check = _top_folders(f"{name}:", binary, run)
    if (
        changed.returncode != 0
        or now.get("client_id") != client_id
        or check is None
        or set(check) != set(after)
    ):
        conf.write_bytes(kept.read_bytes())
        raise OwnClientError(
            f"{name} did not work after the change, so it was put back as it was. "
            "Backups carry on through rclone's shared client."
        )
    return {"remote": name, "clientId": client_id, "folders": len(after), "kept": str(kept)}


def _config_show(name: str, binary: str, run) -> dict[str, str] | None:
    try:
        out = run([binary, "config", "show", name], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    found = {}
    for line in out.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            found[key.strip()] = value.strip()
    return found


def _config_file(
    binary: str, run, error: type[Exception] = OwnClientError, create: bool = False
) -> Path:
    """The rclone config file. With `create`, one that does not exist yet is fine."""
    out = run([binary, "config", "file"], capture_output=True, text=True, timeout=20)
    lines = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
    if out.returncode != 0 or not lines or not (create or Path(lines[-1]).is_file()):
        raise error("could not find the rclone config file, so nothing was changed.")
    return Path(lines[-1])


def _refuse_while_rclone_runs(binary: str, run) -> None:
    out = run(["pgrep", "-x", Path(binary).name], capture_output=True, text=True, timeout=20)
    if out.returncode == 0:
        raise OwnClientError(
            "an upload is running. Signing in again now would be undone when it refreshes "
            "its sign-in, so try again once it has finished."
        )


def _authorize(client_id: str, client_secret: str, binary: str, run) -> str:
    """The token from signing in in the browser, as rclone stores it."""
    try:
        out = run(
            [binary, "authorize", "drive", client_id, client_secret],
            capture_output=True,
            text=True,
            timeout=AUTHORIZE_SECONDS,
        )
    except subprocess.TimeoutExpired:
        raise OwnClientError(
            "the sign-in was not finished in the browser within 10 minutes."
        ) from None
    except OSError as e:
        raise OwnClientError(f"rclone could not start: {e}") from None
    token = parse_authorize(out.stdout)
    if out.returncode != 0 or token is None:
        said = (out.stderr or "").strip().splitlines()
        raise OwnClientError(
            "Google did not sign in with that client"
            + (f": {said[-1]}" if said else ".")
            + " Check the client is a Desktop app and the ID and secret were copied in full."
        )
    return token


def parse_authorize(text: str) -> str | None:
    """`rclone authorize`: the token JSON it prints between its paste markers."""
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                token = json.loads(line)
            except ValueError:
                continue
            if isinstance(token, dict) and token.get("access_token"):
                return line
    return None


def _top_folders(
    target: str, binary: str, run, env: dict[str, str] | None = None
) -> dict[str, str] | None:
    """{id: name} of the folders at the top of a Google Drive, or None when it cannot be read."""
    try:
        out = run(
            [binary, "lsjson", "--dirs-only", target],
            capture_output=True,
            text=True,
            timeout=120,
            env={**os.environ, **env} if env else None,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        entries = json.loads(out.stdout)
    except ValueError:
        return None
    return {e["ID"]: e.get("Name", "") for e in entries if isinstance(e, dict) and e.get("ID")}


def _same_drive(before: dict[str, str] | None, after: dict[str, str], destination: str) -> None:
    """The new sign-in reaches the Google Drive that holds the backups."""
    if before:
        if set(before) != set(after):
            raise OwnClientError(
                "that sign-in opens a different Google Drive from the one holding your backups. "
                "Sign in as the Google account your backups are in. Nothing was changed."
            )
        return
    top = PurePosixPath(destination.strip("/")).parts[:1]
    if top and top[0] not in after.values():
        raise OwnClientError(
            f"that Google Drive has no {top[0]} folder, so it is not the one holding your "
            "backups. Sign in as the Google account your backups are in. Nothing was changed."
        )


class AddS3Error(Exception):
    """Why an S3 account was not added. The rclone config is left as it was."""


#: Written to the bucket and deleted again to prove the keys can upload.
S3_PROBE = ".photo-sentinel-check"


def _quoted(value: str) -> str:
    """A connection string value: quoted, with a quote doubled, so commas and colons pass."""
    return '"' + value.replace('"', '""') + '"'


def s3_target(bucket: str, access_key_id: str, secret: str, region: str, endpoint: str = "") -> str:
    """The alias target: an S3 connection string rooted at the bucket (and folder)."""
    params = [
        "s3",
        f"provider={'Other' if endpoint else 'AWS'}",
        f"access_key_id={_quoted(access_key_id)}",
        f"secret_access_key={_quoted(secret)}",
        f"region={_quoted(region)}",
    ]
    if endpoint:
        params.append(f"endpoint={_quoted(endpoint)}")
    return ":" + ",".join(params) + ":" + bucket.strip("/")


def add_s3(
    name: str,
    bucket: str,
    access_key_id: str,
    secret: str,
    region: str = "us-east-1",
    endpoint: str = "",
    binary: str = "rclone",
    run=subprocess.run,
) -> dict[str, object]:
    """Add an S3 bucket as a backup account, without Terminal.

    The account is an rclone alias rooted at the bucket, so backup folders land
    inside it, and it is listed as S3 (checked by MD5). The keys go straight into
    the rclone config file, never onto a command line where `ps` shows them. The
    account is kept only if a small file can be written to the bucket, read back
    and deleted; otherwise the config file is put back as it was.
    """
    name, bucket = name.strip().rstrip(":"), bucket.strip().strip("/")
    access_key_id, secret = access_key_id.strip(), secret.strip()
    region, endpoint = region.strip() or "us-east-1", endpoint.strip()
    if not name or not all(c.isalnum() or c in "-_" for c in name):
        raise AddS3Error("the account name may use only letters, digits, - and _.")
    if not bucket:
        raise AddS3Error("the bucket name is empty.")
    if not access_key_id or not secret:
        raise AddS3Error("both the access key ID and the secret access key are needed.")
    if endpoint and not endpoint.startswith(("https://", "http://")):
        endpoint = "https://" + endpoint
    if any(a.name == name for a in accounts(binary, run)):
        raise AddS3Error(f"there is already an account called {name}. Pick another name.")

    conf = _config_file(binary, run, AddS3Error, create=True)
    before = conf.read_bytes() if conf.exists() else None
    if before is not None and before.lstrip().startswith(b"RCLONE_ENCRYPT"):
        raise AddS3Error("your rclone config is encrypted, so add the account with rclone config.")
    text = (before or b"").decode()
    target = s3_target(bucket, access_key_id, secret, region, endpoint)
    section = f"\n[{name}]\ntype = alias\nremote = {target}\n"
    conf.parent.mkdir(parents=True, exist_ok=True)
    conf.write_text(text.rstrip("\n") + ("\n" if text.strip() else "") + section)
    conf.chmod(0o600)

    def undo(why: str) -> AddS3Error:
        if before is None:
            conf.unlink(missing_ok=True)
        else:
            conf.write_bytes(before)
        return AddS3Error(why + " Nothing was added.")

    probe = f"{name}:{S3_PROBE}"
    try:
        wrote = run(
            [binary, "rcat", probe], input="ok\n", capture_output=True, text=True, timeout=60
        )
        if wrote.returncode != 0:
            said = (wrote.stderr or "").strip().splitlines()
            raise undo(
                "the bucket could not be written to"
                + (f": {said[-1]}" if said else ".")
                + " Check the bucket name, region and keys, and that the keys may upload."
            )
        read = run([binary, "lsjson", "--hash", probe], capture_output=True, text=True, timeout=60)
        rows = json.loads(read.stdout) if read.returncode == 0 and read.stdout.strip() else []
        if not any((r.get("Hashes") or {}).get("md5") for r in rows if isinstance(r, dict)):
            raise undo(
                "the test file was written but S3 did not report its MD5, so backups "
                "there could not be checked."
            )
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        raise undo(f"rclone could not reach the bucket: {e}.") from None
    finally:
        with contextlib.suppress(OSError, subprocess.SubprocessError):
            run([binary, "deletefile", probe], capture_output=True, text=True, timeout=60)
    return {"remote": name, "kind": "s3", "bucket": bucket, "endpoint": endpoint, "region": region}
