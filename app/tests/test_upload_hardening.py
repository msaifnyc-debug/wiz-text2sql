"""Security test matrix for untrusted .db upload handling (web/storage.py)."""

import io
import sqlite3

import pytest

from web import settings, storage


def _make_sqlite_bytes(tmp_path) -> bytes:
    p = tmp_path / "seed.db"
    conn = sqlite3.connect(p)
    conn.execute("CREATE TABLE t (a INTEGER, b TEXT)")
    conn.execute("INSERT INTO t VALUES (1, 'x'), (2, 'y')")
    conn.commit()
    conn.close()
    return p.read_bytes()


@pytest.fixture(autouse=True)
def _isolate_uploads(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "UPLOAD_DIR", tmp_path / "uploads")


def test_accepts_valid_sqlite(tmp_path):
    data = _make_sqlite_bytes(tmp_path)
    stored = storage.validate_and_store("user1", "mine.db", io.BytesIO(data))
    assert stored.tables == ["t"]
    assert stored.size_bytes == len(data)
    assert stored.path.exists()


def test_rejects_non_sqlite_by_magic_header(tmp_path):
    # A file that claims to be .db but is not SQLite (controls the extension, not the bytes).
    with pytest.raises(storage.UploadError):
        storage.validate_and_store("user1", "evil.db", io.BytesIO(b"#!/bin/sh\nrm -rf /\n"))


def test_rejects_empty_file(tmp_path):
    with pytest.raises(storage.UploadError):
        storage.validate_and_store("user1", "empty.db", io.BytesIO(b""))


def test_enforces_size_cap(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "MAX_UPLOAD_BYTES", 1024)  # 1 KiB cap
    data = _make_sqlite_bytes(tmp_path)
    assert len(data) > 1024
    with pytest.raises(storage.UploadError):
        storage.validate_and_store("user1", "big.db", io.BytesIO(data))
    # Rejected upload must leave nothing behind.
    assert not list((settings.UPLOAD_DIR / "user1").glob("*.db"))


def test_rejected_upload_is_cleaned_up(tmp_path):
    with pytest.raises(storage.UploadError):
        storage.validate_and_store("user1", "evil.db", io.BytesIO(b"not-sqlite"))
    assert not list((settings.UPLOAD_DIR / "user1").glob("*.db"))


def test_hardened_connection_is_read_only(tmp_path):
    data = _make_sqlite_bytes(tmp_path)
    stored = storage.validate_and_store("user1", "mine.db", io.BytesIO(data))
    conn = storage.open_hardened(stored.path)
    try:
        # Reads work.
        assert conn.execute("SELECT COUNT(*) FROM t").fetchone()[0] == 2
        # Writes are refused even though the SQL guard isn't in this path.
        with pytest.raises(sqlite3.OperationalError):
            conn.execute("INSERT INTO t VALUES (3, 'z')")
        with pytest.raises(sqlite3.OperationalError):
            conn.execute("CREATE TABLE evil (x)")
    finally:
        conn.close()


def test_per_user_isolation_paths(tmp_path):
    data = _make_sqlite_bytes(tmp_path)
    a = storage.validate_and_store("alice", "a.db", io.BytesIO(data))
    b = storage.validate_and_store("bob", "b.db", io.BytesIO(data))
    assert "alice" in str(a.path) and "bob" in str(b.path)
    assert a.path.parent != b.path.parent
