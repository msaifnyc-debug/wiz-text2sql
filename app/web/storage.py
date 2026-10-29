"""Untrusted `.db` upload handling and SQLite hardening.

The product lets a user upload *their own* SQLite database and query it in natural
language. That upload is untrusted input, so this module is the application-layer
of our defense-in-depth story:

  * **Validate it is really SQLite** - check the 16-byte magic header, not the
    filename extension (which an attacker controls).
  * **Bound it** - stream to disk with a hard size cap; never buffer the whole
    file in memory; never trust the client-supplied filename for the path
    (store under a server-generated UUID -> no path traversal).
  * **Open it read-only** - URI ``mode=ro&immutable=1`` + ``PRAGMA query_only=ON``
    so no query can write, even if one slipped past the SQL guard.
  * **Disable extensions** - blocks ``load_extension`` and the filesystem funcs
    (``readfile``/``writefile``) that ship with it. Python disables this by
    default; we assert it off explicitly.
  * **Harden the schema surface** - ``PRAGMA trusted_schema=OFF`` so views/triggers
    in a malicious file can't invoke privileged functions.
  * **Cap runtime** - a progress handler aborts a query that runs past a wall-clock
    deadline (DoS guard against a pathological query or a crafted huge table).

These complement (not replace) the read-only SQL guard in ``src/checker.py``.
"""

from __future__ import annotations

import hashlib
import sqlite3
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, List

from . import settings

SQLITE_MAGIC = b"SQLite format 3\x00"  # 16 bytes at offset 0 of every SQLite file


class UploadError(Exception):
    """Raised for an invalid/too-large/unsafe upload; surfaced as HTTP 400."""


@dataclass
class StoredDB:
    db_id: str
    filename: str          # original name, for display only
    path: Path
    size_bytes: int
    sha256: str
    tables: List[str]


def _user_dir(user_id: str) -> Path:
    d = settings.UPLOAD_DIR / user_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def db_path(user_id: str, db_id: str) -> Path:
    return _user_dir(user_id) / f"{db_id}.db"


def validate_and_store(user_id: str, filename: str, stream: BinaryIO) -> StoredDB:
    """Stream an upload to disk with a size cap, validate it, and register it.

    We write first (bounded), then validate the header + openability, deleting the
    file if anything fails so a rejected upload leaves nothing behind.
    """
    db_id = uuid.uuid4().hex
    dest = db_path(user_id, db_id)
    hasher = hashlib.sha256()
    size = 0

    try:
        with open(dest, "wb") as out:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > settings.MAX_UPLOAD_BYTES:
                    raise UploadError(
                        f"file exceeds the {settings.MAX_UPLOAD_BYTES // (1024*1024)} MiB limit"
                    )
                hasher.update(chunk)
                out.write(chunk)

        if size == 0:
            raise UploadError("empty file")

        with open(dest, "rb") as f:
            if f.read(16) != SQLITE_MAGIC:
                raise UploadError("not a valid SQLite database (bad magic header)")

        # Prove it opens read-only and enumerate tables for the registry.
        tables = _list_tables(dest)
        if not tables:
            raise UploadError("database contains no tables")

    except UploadError:
        dest.unlink(missing_ok=True)
        raise
    except sqlite3.Error as e:
        dest.unlink(missing_ok=True)
        raise UploadError(f"could not open as SQLite: {e}") from e

    return StoredDB(
        db_id=db_id,
        filename=Path(filename).name,  # strip any path components defensively
        path=dest,
        size_bytes=size,
        sha256=hasher.hexdigest(),
        tables=tables,
    )


def open_hardened(path: Path) -> sqlite3.Connection:
    """Open an uploaded DB read-only, immutable, query-only, extensions off, with a
    wall-clock abort handler. The agent runs all its queries through this."""
    uri = f"file:{path}?mode=ro&immutable=1"
    conn = sqlite3.connect(uri, uri=True, check_same_thread=False)
    conn.row_factory = sqlite3.Row

    # Extension loading is off by default in CPython's sqlite3; assert it.
    try:
        conn.enable_load_extension(False)
    except AttributeError:
        pass  # built without extension support -> already safe

    conn.execute("PRAGMA query_only = ON")
    conn.execute("PRAGMA trusted_schema = OFF")

    _install_timeout(conn, settings.QUERY_TIMEOUT_S)
    return conn


def _install_timeout(conn: sqlite3.Connection, seconds: float) -> None:
    deadline = time.monotonic() + seconds

    def _abort_if_over_budget() -> int:
        # Non-zero return aborts the running statement with OperationalError.
        return 1 if time.monotonic() > deadline else 0

    # Called roughly every N bytecode ops; frequent enough to bound CPU-bound scans.
    conn.set_progress_handler(_abort_if_over_budget, 5000)


def _list_tables(path: Path) -> List[str]:
    conn = open_hardened(path)
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).fetchall()
        return [r[0] for r in rows]
    finally:
        conn.close()
