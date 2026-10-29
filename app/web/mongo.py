"""MongoDB access layer.

This is how the app "leverages MongoDB" per the exercise: three collections form
the app's system-of-record, entirely separate from the SQLite file a user uploads
to be *queried*.

  users      - account records (email, bcrypt hash, created_at)
  databases  - uploaded-DB registry (owner, filename, sha256, size, tables, path)
  history    - query log (owner, db_id, question, sql, success, latency, tokens)

Indexes are created lazily on first connection.
"""

from __future__ import annotations

from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Dict, List, Optional

from pymongo import ASCENDING, DESCENDING, MongoClient
from pymongo.collection import Collection
from pymongo.database import Database

from . import settings


@lru_cache(maxsize=1)
def _client() -> MongoClient:
    return MongoClient(
        settings.MONGODB_URI,
        serverSelectionTimeoutMS=settings.MONGO_TIMEOUT_MS,
        connectTimeoutMS=settings.MONGO_TIMEOUT_MS,
    )


def db() -> Database:
    return _client()[settings.MONGO_DB_NAME]


def users() -> Collection:
    return db()["users"]


def databases() -> Collection:
    return db()["databases"]


def history() -> Collection:
    return db()["history"]


def ensure_indexes() -> None:
    """Idempotent; safe to call at startup."""
    users().create_index([("email", ASCENDING)], unique=True)
    databases().create_index([("owner", ASCENDING), ("created_at", DESCENDING)])
    history().create_index([("owner", ASCENDING), ("created_at", DESCENDING)])


def ping() -> bool:
    """Lightweight health check used by /healthz."""
    try:
        _client().admin.command("ping")
        return True
    except Exception:
        return False


def now() -> datetime:
    return datetime.now(timezone.utc)


# --- small typed helpers the routes use ---------------------------------------
def record_history(
    owner: str,
    db_id: Optional[str],
    question: str,
    sql: Optional[str],
    success: bool,
    latency_s: float,
    prompt_tokens: int,
    completion_tokens: int,
    kind: str = "sql",
) -> None:
    history().insert_one(
        {
            "owner": owner,
            "db_id": db_id,
            "question": question,
            "sql": sql,
            "success": success,
            "kind": kind,
            "latency_s": round(latency_s, 3),
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "created_at": now(),
        }
    )


def recent_history(owner: str, db_id: str, limit: int) -> List[Dict[str, Any]]:
    """Most recent successful turns for (owner, db), oldest-first for replay."""
    cur = (
        history()
        .find({"owner": owner, "db_id": db_id, "success": True, "sql": {"$ne": None}})
        .sort("created_at", DESCENDING)
        .limit(limit)
    )
    return list(reversed(list(cur)))
