"""Bridge between the web layer and the reused text-to-SQL agent.

For each question we open a *hardened* read-only connection to the user's uploaded
DB (see storage.py), build the agent around it (reusing ``src/agent.py`` untouched),
replay a few prior turns from MongoDB for follow-up context, answer, then persist
the turn. The agent's schema cache is fingerprint-keyed, so each different uploaded
DB is isolated automatically.
"""

from __future__ import annotations

from typing import Any, Dict, List

from src import config
from src.agent import TextToSQLAgent

from . import mongo, settings, storage


class AgentUnavailable(Exception):
    """Raised when the agent can't run (e.g. FIREWORKS_API_KEY not configured)."""


def _jsonable(value: Any) -> Any:
    if isinstance(value, (bytes, bytearray)):
        return value.decode("utf-8", "replace")
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def _shape(res) -> Dict[str, Any]:
    rows: List[Dict[str, Any]] = [
        {k: _jsonable(v) for k, v in row.items()} for row in res.rows
    ]
    return {
        "success": res.success,
        "kind": res.kind,
        "sql": res.sql,
        "explanation": res.explanation,
        "reply": res.reply,
        "columns": res.columns,
        "rows": rows,
        "row_count": len(rows),
        "error": res.error,
        "repaired": res.repaired,
        "failed_over": res.failed_over,
        "model": res.model,
        "latency_s": round(res.latency_s, 3),
        "attempts": res.num_attempts,
        "prompt_tokens": res.prompt_tokens,
        "completion_tokens": res.completion_tokens,
    }


def answer_question(user_id: str, db_doc: Dict[str, Any], question: str) -> Dict[str, Any]:
    """Run one NL question against the user's selected uploaded DB."""
    if not config.has_api_key():
        raise AgentUnavailable(
            "FIREWORKS_API_KEY is not configured on the server."
        )

    path = storage.db_path(user_id, db_doc["db_id"])
    if not path.exists():
        raise AgentUnavailable("the selected database file is missing on the server")

    conn = storage.open_hardened(path)
    try:
        agent = TextToSQLAgent(conn, db_path=str(path))
        # Replay recent successful turns so follow-up questions have context.
        for turn in mongo.recent_history(user_id, db_doc["db_id"], settings.HISTORY_TURNS):
            agent.history.append({"question": turn["question"], "sql": turn["sql"]})

        res = agent.answer(question)
    finally:
        conn.close()

    mongo.record_history(
        owner=user_id,
        db_id=db_doc["db_id"],
        question=question,
        sql=res.sql,
        success=res.success,
        latency_s=res.latency_s,
        prompt_tokens=res.prompt_tokens,
        completion_tokens=res.completion_tokens,
        kind=res.kind,
    )
    return _shape(res)
