"""Validation layer.

Two responsibilities, both reused elsewhere:

1. **Pre-execution guard** (safety + sanity): the tool points at the *customer's*
   database, so we hard-reject anything that isn't a single read-only SELECT, and
   statically lint with ``sqlglot`` to catch malformed SQL before paying to run it.

2. **Post-execution verifier** (correctness): compare a result set against an
   expected one. This is the metric the eval harness scores on, and it can also
   gate auto-retry online.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import permutations
from typing import Any, List, Optional, Sequence

import sqlglot
from sqlglot import expressions as exp

# Statement types that write or change state — never allowed.
_FORBIDDEN = (
    exp.Insert, exp.Update, exp.Delete, exp.Drop, exp.Create,
    exp.Alter, exp.TruncateTable, exp.Command,
)


@dataclass
class GuardResult:
    ok: bool
    reason: Optional[str] = None
    normalized_sql: Optional[str] = None


def guard(sql: str) -> GuardResult:
    """Ensure ``sql`` is a single, read-only SELECT and parses cleanly."""
    if not sql or not sql.strip():
        return GuardResult(False, "empty query")

    try:
        statements = sqlglot.parse(sql, read="sqlite")
    except sqlglot.errors.SqlglotError as e:
        # Catches ParseError, TokenError, etc. (e.g. unterminated string literals).
        return GuardResult(False, f"could not parse SQL: {e}")

    statements = [s for s in statements if s is not None]
    if len(statements) != 1:
        return GuardResult(False, "only a single statement is allowed")

    stmt = statements[0]
    for node in stmt.walk():
        if isinstance(node, _FORBIDDEN):
            return GuardResult(False, "only read-only SELECT queries are allowed")

    # Top-level must be a SELECT (or a WITH ... SELECT / set operation).
    root = stmt
    if not isinstance(root, (exp.Select, exp.Union, exp.Except, exp.Intersect, exp.With, exp.Subquery)):
        return GuardResult(False, "query must be a SELECT statement")

    return GuardResult(True, normalized_sql=stmt.sql(dialect="sqlite"))


def _normalize_value(v: Any) -> Any:
    """Make values comparable across float rounding and numeric/str drift."""
    if isinstance(v, float):
        return round(v, 2)
    if isinstance(v, int):
        return round(float(v), 2)
    if isinstance(v, str):
        s = v.strip()
        try:
            return round(float(s), 2)
        except ValueError:
            return s
    return v


def _normalize_rows(rows: Sequence[dict]) -> List[tuple]:
    """Row dicts -> list of value tuples, comparing by position not column name.

    Column *names* differ harmlessly between gold and predicted SQL (aliases), so
    we compare the ordered values instead.
    """
    out = []
    for row in rows:
        out.append(tuple(_normalize_value(v) for v in row.values()))
    return out


@dataclass
class MatchResult:
    match: bool
    reason: str


def result_sets_match(
    predicted: Sequence[dict],
    expected: Sequence[dict],
    order_matters: bool,
) -> MatchResult:
    """Compare two result sets by value.

    ``order_matters`` should be True when the question implies an ordering
    (top-N, ranked, "ordered from highest to lowest").
    """
    p = _normalize_rows(predicted)
    e = _normalize_rows(expected)

    if len(p) != len(e):
        return MatchResult(False, f"row count {len(p)} != expected {len(e)}")

    if order_matters:
        ok = p == e
        return MatchResult(ok, "ok" if ok else "rows differ in ordered comparison")

    ok = sorted(map(repr, p)) == sorted(map(repr, e))
    return MatchResult(ok, "ok" if ok else "rows differ in unordered comparison")


def _project(rows: Sequence[dict], idx_order: Sequence[int]) -> List[dict]:
    out = []
    for row in rows:
        vals = list(row.values())
        out.append({j: vals[i] for j, i in enumerate(idx_order)})
    return out


def result_sets_match_lenient(
    predicted: Sequence[dict],
    expected: Sequence[dict],
    order_matters: bool,
) -> MatchResult:
    """Like ``result_sets_match`` but tolerant of *extra* predicted columns.

    Many correct queries return additional context columns (e.g. an ``Id`` column
    alongside the answer). We accept the prediction if any ordered projection of
    its columns onto the expected width reproduces the expected result. Result
    widths are tiny here, so the permutation search is cheap.
    """
    if not predicted and not expected:
        return MatchResult(True, "ok")
    exp_width = len(expected[0]) if expected else 0
    pred_width = len(predicted[0]) if predicted else 0

    if pred_width < exp_width:
        return MatchResult(False, "prediction has fewer columns than expected")

    for combo in permutations(range(pred_width), exp_width):
        projected = _project(predicted, combo)
        if result_sets_match(projected, expected, order_matters).match:
            return MatchResult(True, "ok (matched on column subset)")
    return MatchResult(False, "no column projection reproduces expected result")


_ORDER_KEYWORDS = (
    "top ", "ranked", "rank ", "order", "highest", "lowest",
    "most ", "least ", "best", "worst", "first ", "last ", "largest", "smallest",
)


def question_implies_order(question: str) -> bool:
    q = question.lower()
    return any(kw in q for kw in _ORDER_KEYWORDS)
