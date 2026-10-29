"""Schema introspection with a fingerprint-keyed, version-gated cache.

The agent grounds every prompt in the live database schema to prevent the model
from hallucinating table/column names. Because the schema can be large (think a
200-table warehouse, not just Chinook) we introspect once, compile a compact
`CREATE TABLE`-style description, and cache it:

  * keyed by a *fingerprint* (db path + SQLite ``PRAGMA schema_version``) so the
    same process can serve multiple databases safely;
  * persisted to disk so repeat launches skip introspection;
  * invalidated automatically when the schema version bumps (any DDL) and lazily
    when a query fails with a "no such table/column" error.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional

from . import config
from .utils import query_db


def schema_version(conn: sqlite3.Connection) -> int:
    """Cheap integer that SQLite bumps on any DDL change."""
    rows = query_db(conn, "PRAGMA schema_version", return_as_df=False)
    return int(rows[0]["schema_version"]) if rows else 0


def fingerprint(conn: sqlite3.Connection, db_path: str) -> str:
    """Stable id for (database identity + schema version)."""
    raw = f"{Path(db_path).resolve()}::{schema_version(conn)}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


@dataclass
class SchemaSnapshot:
    fingerprint: str
    version: int
    ddl: str          # human/LLM-friendly compiled schema
    tables: List[str]

    def to_dict(self) -> dict:
        return asdict(self)


def _compile_ddl(conn: sqlite3.Connection, sample_values: bool = True) -> tuple[str, List[str]]:
    """Build a compact schema description: tables, typed columns, PK/FK, samples."""
    tables = query_db(
        conn,
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
        return_as_df=False,
    )
    table_names = [t["name"] for t in tables]
    blocks: List[str] = []

    for name in table_names:
        cols = query_db(conn, f"PRAGMA table_info('{name}')", return_as_df=False)
        fks = query_db(conn, f"PRAGMA foreign_key_list('{name}')", return_as_df=False)
        fk_by_col = {fk["from"]: (fk["table"], fk["to"]) for fk in fks}

        lines = [f"CREATE TABLE {name} ("]
        col_defs = []
        for c in cols:
            parts = [f"  {c['name']}", c["type"] or "TEXT"]
            if c["pk"]:
                parts.append("PRIMARY KEY")
            if c["notnull"]:
                parts.append("NOT NULL")
            if c["name"] in fk_by_col:
                ref_tbl, ref_col = fk_by_col[c["name"]]
                parts.append(f"REFERENCES {ref_tbl}({ref_col})")
            col_defs.append(" ".join(parts))
        lines.append(",\n".join(col_defs))
        lines.append(");")
        block = "\n".join(lines)

        if sample_values:
            sample = _sample_row(conn, name)
            if sample:
                block += f"\n-- sample: {sample}"
        blocks.append(block)

    return "\n\n".join(blocks), table_names


def _sample_row(conn: sqlite3.Connection, table: str) -> Optional[str]:
    """One example row to give the model a feel for the data (values truncated)."""
    try:
        rows = query_db(conn, f"SELECT * FROM '{table}' LIMIT 1", return_as_df=False)
    except sqlite3.Error:
        return None
    if not rows:
        return None
    trimmed = {k: (str(v)[:40] if v is not None else None) for k, v in rows[0].items()}
    return json.dumps(trimmed, ensure_ascii=False, default=str)


class SchemaCache:
    """In-memory + on-disk schema cache, gated on the DB fingerprint."""

    def __init__(self, db_path: str, cache_dir: str = config.CACHE_DIR):
        self.db_path = db_path
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._snapshot: Optional[SchemaSnapshot] = None

    def _disk_path(self, fp: str) -> Path:
        return self.cache_dir / f"schema_{fp}.json"

    def get(self, conn: sqlite3.Connection, force_refresh: bool = False) -> SchemaSnapshot:
        fp = fingerprint(conn, self.db_path)

        if not force_refresh and self._snapshot and self._snapshot.fingerprint == fp:
            return self._snapshot

        if not force_refresh:
            disk = self._load_disk(fp)
            if disk:
                self._snapshot = disk
                return disk

        ddl, tables = _compile_ddl(conn)
        snapshot = SchemaSnapshot(
            fingerprint=fp, version=schema_version(conn), ddl=ddl, tables=tables
        )
        self._snapshot = snapshot
        self._save_disk(snapshot)
        return snapshot

    def invalidate(self) -> None:
        """Drop the in-memory snapshot so the next get() re-introspects."""
        self._snapshot = None

    def _load_disk(self, fp: str) -> Optional[SchemaSnapshot]:
        path = self._disk_path(fp)
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text())
            return SchemaSnapshot(**data)
        except (json.JSONDecodeError, TypeError):
            return None

    def _save_disk(self, snapshot: SchemaSnapshot) -> None:
        try:
            self._disk_path(snapshot.fingerprint).write_text(
                json.dumps(snapshot.to_dict(), ensure_ascii=False, indent=2)
            )
        except OSError:
            pass  # caching is best-effort; never block a query on it


# Signals in a SQLite error message that mean our cached schema is likely stale.
STALE_SCHEMA_MARKERS = ("no such table", "no such column")


def looks_like_stale_schema(error_message: str) -> bool:
    msg = error_message.lower()
    return any(marker in msg for marker in STALE_SCHEMA_MARKERS)
