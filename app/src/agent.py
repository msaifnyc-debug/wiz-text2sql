"""Text-to-SQL agent.

Design (see README discussion):
  * **Schema grounding** — every prompt carries the live, cached schema so the
    model can't hallucinate tables/columns.
  * **Structured output** — the model returns JSON ``{sql, explanation}``; we parse
    robustly (with a markdown-fence fallback) instead of regex-scraping prose.
  * **Self-correction loop** — generated SQL is guarded then executed; on a SQLite
    error we feed the message back and retry (capped, to protect latency).
  * **Fallback ladder** — stale-schema errors trigger re-introspection + retry;
    API/model errors fail over to a secondary model; everything degrades to a
    clear message with the last attempt rather than a stack trace.

The same agent powers the CLI, the eval harness, and the perf harness.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from openai import OpenAI, OpenAIError

from . import config
from .checker import guard
from .schema import SchemaCache, looks_like_stale_schema
from .utils import query_db


SYSTEM_PROMPT_TEMPLATE = """You are an expert data analyst that translates natural language questions into SQLite SQL.

Rules:
- Use ONLY the tables and columns in the schema below. Never invent names.
- The database is SQLite. Use SQLite syntax (e.g. strftime for dates).
- Produce a single, read-only SELECT statement. Never write/modify data.
- Prefer explicit JOINs with ON clauses. Alias tables for readability.
- When the question implies an ordering or a "top N", include ORDER BY (and LIMIT).
- If the question is ambiguous, make a reasonable assumption and state it briefly.

You respond in one of two modes via a JSON object:
- DATA question (needs to query the database):
  {{"kind": "sql", "sql": "<SELECT ...>", "explanation": "<one sentence>"}}
- FOLLOW-UP question ABOUT the previous result (its units, meaning, or formatting)
  that needs NO new data:
  {{"kind": "reply", "reply": "<concise plain-language answer>"}}

Default to "sql" whenever the user is asking for data. Only use "reply" for
clarifying questions about the answer you just gave (e.g. "is that in dollars?",
"what does that column mean?"). Note: monetary values in this database are in its
base currency (US dollars), computed from unit price x quantity.

Database schema:
{schema}

{examples}"""

# A few curated examples covering join / aggregation / window patterns.
FEW_SHOT_EXAMPLES = """Examples:
Q: How many customers are there?
{"sql": "SELECT COUNT(*) AS CustomerCount FROM Customer", "explanation": "Counts all rows in Customer."}

Q: Which 3 artists have the most albums?
{"sql": "SELECT ar.Name AS ArtistName, COUNT(al.AlbumId) AS AlbumCount FROM Artist ar JOIN Album al ON ar.ArtistId = al.ArtistId GROUP BY ar.ArtistId, ar.Name ORDER BY AlbumCount DESC LIMIT 3", "explanation": "Joins artists to albums, counts albums per artist, returns the top 3."}
"""


def _summarize(result: "QueryResult", max_rows: int = 5) -> str:
    """Compact text summary of a result, used as context for follow-up questions."""
    if not result.rows:
        return f"columns={result.columns}, 0 rows"
    preview = result.rows[:max_rows]
    suffix = "" if len(result.rows) <= max_rows else f" (+{len(result.rows)-max_rows} more rows)"
    return f"columns={result.columns}, rows={preview}{suffix}"


@dataclass
class Attempt:
    sql: str
    ok: bool
    error: Optional[str] = None


@dataclass
class QueryResult:
    """Everything the CLI / evals / perf need about one answered question."""

    question: str
    sql: Optional[str]
    rows: List[dict] = field(default_factory=list)
    columns: List[str] = field(default_factory=list)
    success: bool = False
    error: Optional[str] = None
    explanation: Optional[str] = None

    kind: str = "sql"          # "sql" (ran a query) or "reply" (conversational)
    reply: Optional[str] = None  # set when kind == "reply"
    model: str = ""
    attempts: List[Attempt] = field(default_factory=list)
    repaired: bool = False
    failed_over: bool = False

    # Telemetry for perf/cost.
    latency_s: float = 0.0
    model_latency_s: float = 0.0
    prompt_tokens: int = 0
    completion_tokens: int = 0

    @property
    def num_attempts(self) -> int:
        return len(self.attempts)


class TextToSQLAgent:
    def __init__(
        self,
        conn: sqlite3.Connection,
        db_path: str = config.DB_PATH,
        model: str = config.PRIMARY_MODEL,
        fast_model: str = config.FAST_MODEL,
        max_repair_attempts: int = config.MAX_REPAIR_ATTEMPTS,
    ):
        self.conn = conn
        self.db_path = db_path
        self.model = model
        self.fast_model = fast_model
        self.max_repair_attempts = max_repair_attempts
        self.schema_cache = SchemaCache(db_path)
        self.history: List[Dict[str, str]] = []  # prior (question, sql) turns

        if not config.has_api_key():
            raise RuntimeError(
                "FIREWORKS_API_KEY is not set. Export it or add it to a .env file."
            )
        self.client = OpenAI(
            base_url=config.FIREWORKS_BASE_URL,
            api_key=config.FIREWORKS_API_KEY,
            timeout=config.REQUEST_TIMEOUT,
        )

    # ----- prompt construction -------------------------------------------------
    def _system_prompt(self) -> str:
        snapshot = self.schema_cache.get(self.conn)
        return SYSTEM_PROMPT_TEMPLATE.format(
            schema=snapshot.ddl, examples=FEW_SHOT_EXAMPLES
        )

    def _build_messages(self, question: str, repair_error: Optional[str], last_sql: Optional[str]):
        messages: List[Dict[str, str]] = [{"role": "system", "content": self._system_prompt()}]
        # Lightweight conversational context: prior question/SQL pairs.
        for turn in self.history[-4:]:
            messages.append({"role": "user", "content": turn["question"]})
            messages.append({"role": "assistant", "content": json.dumps({"sql": turn["sql"]})})
        # Give the model the most recent result so it can answer follow-ups about it.
        if self.history and self.history[-1].get("summary"):
            messages.append(
                {
                    "role": "system",
                    "content": f"For reference, your previous query returned: {self.history[-1]['summary']}",
                }
            )

        if repair_error and last_sql:
            messages.append({"role": "user", "content": question})
            messages.append({"role": "assistant", "content": json.dumps({"sql": last_sql})})
            messages.append(
                {
                    "role": "user",
                    "content": (
                        f"That query failed with this error:\n{repair_error}\n"
                        "Fix the SQL. Respond with the same JSON format."
                    ),
                }
            )
        else:
            messages.append({"role": "user", "content": question})
        return messages

    # ----- model call ----------------------------------------------------------
    def _call_model(self, messages, model: str):
        last_exc: Optional[Exception] = None
        extra_body = {"reasoning_effort": config.REASONING_EFFORT} if config.REASONING_EFFORT else {}
        for attempt in range(3):
            try:
                return self.client.chat.completions.create(
                    model=model,
                    messages=messages,
                    temperature=config.TEMPERATURE,
                    max_tokens=config.MAX_TOKENS,
                    response_format={"type": "json_object"},
                    extra_body=extra_body,
                )
            except OpenAIError as e:
                last_exc = e
                if "429" in str(e) and attempt < 2:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise
        raise last_exc  # pragma: no cover

    @staticmethod
    def _parse_response(content: str) -> Dict[str, Optional[str]]:
        """Parse the model's JSON response, defensively. Returns a dict with
        keys: kind, sql, explanation, reply."""
        content = (content or "").strip()
        # Strip markdown fences if the model wrapped its JSON.
        if content.startswith("```"):
            content = content.strip("`")
            if content.lower().startswith("json"):
                content = content[4:]
        try:
            data = json.loads(content)
            return {
                "kind": data.get("kind", "sql"),
                "sql": data.get("sql"),
                "explanation": data.get("explanation"),
                "reply": data.get("reply"),
            }
        except json.JSONDecodeError:
            # Last-ditch: pull a SQL-looking substring.
            lowered = content.lower()
            idx = lowered.find("select")
            if idx == -1:
                idx = lowered.find("with")
            if idx != -1:
                return {"kind": "sql", "sql": content[idx:].rstrip("`").strip(),
                        "explanation": None, "reply": None}
            return {"kind": "sql", "sql": None, "explanation": None, "reply": None}

    # ----- main entry point ----------------------------------------------------
    def answer(self, question: str) -> QueryResult:
        result = QueryResult(question=question, sql=None, model=self.model)
        start = time.perf_counter()

        repair_error: Optional[str] = None
        last_sql: Optional[str] = None
        current_model = self.model

        for attempt_no in range(self.max_repair_attempts + 1):
            messages = self._build_messages(question, repair_error, last_sql)

            # --- call the model (with secondary-model failover) ---
            try:
                t0 = time.perf_counter()
                resp = self._call_model(messages, current_model)
                result.model_latency_s += time.perf_counter() - t0
            except OpenAIError as e:
                if not result.failed_over and current_model != self.fast_model:
                    result.failed_over = True
                    current_model = self.fast_model
                    result.model = current_model
                    continue
                result.error = f"Model request failed: {e}"
                break

            if resp.usage:
                result.prompt_tokens += resp.usage.prompt_tokens or 0
                result.completion_tokens += resp.usage.completion_tokens or 0

            parsed = self._parse_response(resp.choices[0].message.content)

            # Conversational follow-up about the previous result — no SQL to run.
            if parsed["kind"] == "reply" and parsed.get("reply"):
                result.kind = "reply"
                result.reply = parsed["reply"]
                result.success = True
                break

            sql = parsed["sql"]
            if not sql:
                repair_error = "Response did not contain SQL."
                result.attempts.append(Attempt(sql="", ok=False, error=repair_error))
                last_sql = None
                continue

            result.sql = sql
            result.explanation = parsed["explanation"]
            last_sql = sql

            # --- pre-execution guard (safety + lint) ---
            g = guard(sql)
            if not g.ok:
                repair_error = g.reason
                result.attempts.append(Attempt(sql=sql, ok=False, error=g.reason))
                continue

            # --- execute ---
            try:
                rows = query_db(self.conn, sql, return_as_df=False)
                result.attempts.append(Attempt(sql=sql, ok=True))
                result.rows = rows[: config.MAX_RESULT_ROWS]
                result.columns = list(rows[0].keys()) if rows else []
                result.success = True
                result.repaired = attempt_no > 0
                break
            except sqlite3.Error as e:
                err = str(e)
                result.attempts.append(Attempt(sql=sql, ok=False, error=err))
                # Stale-schema error: re-introspect once, then retry.
                if looks_like_stale_schema(err):
                    self.schema_cache.invalidate()
                repair_error = err

        result.latency_s = time.perf_counter() - start
        if not result.success and not result.error:
            result.error = (
                result.attempts[-1].error if result.attempts else "No SQL produced."
            )

        if result.success and result.sql:
            self.history.append(
                {"question": question, "sql": result.sql, "summary": _summarize(result)}
            )
        return result

    def reset(self) -> None:
        self.history.clear()

    def refresh_schema(self) -> None:
        self.schema_cache.invalidate()
        self.schema_cache.get(self.conn, force_refresh=True)
