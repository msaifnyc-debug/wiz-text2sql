"""Security test matrix for the read-only SQL guard (src/checker.py).

This is the enforcement boundary we rely on when running model-generated SQL
against an untrusted, user-uploaded database: nothing but a single read-only
SELECT may execute. Each case below is a would-be attack or mistake.
"""

import pytest

from src.checker import guard

ALLOWED = [
    "SELECT 1",
    "SELECT Name FROM Artist LIMIT 5",
    "WITH t AS (SELECT 1 AS n) SELECT n FROM t",
    "SELECT a.x FROM a JOIN b ON a.id = b.id WHERE b.y > 10 ORDER BY a.x",
]

BLOCKED = [
    "",                                             # empty
    "INSERT INTO Artist (Name) VALUES ('x')",       # write
    "UPDATE Artist SET Name = 'x' WHERE 1=1",       # write
    "DELETE FROM Artist",                           # write
    "DROP TABLE Artist",                            # DDL
    "ALTER TABLE Artist ADD COLUMN c TEXT",         # DDL
    "CREATE TABLE evil (a TEXT)",                   # DDL
    "SELECT 1; DROP TABLE Artist",                  # multi-statement / stacked
    "ATTACH DATABASE '/etc/passwd' AS p",           # cross-db escape attempt
    "SELECT * FROM a; SELECT * FROM b",             # multi-statement
]


@pytest.mark.parametrize("sql", ALLOWED)
def test_allows_read_only_selects(sql):
    assert guard(sql).ok, f"expected ALLOWED: {sql!r}"


@pytest.mark.parametrize("sql", BLOCKED)
def test_blocks_writes_ddl_and_stacked(sql):
    assert not guard(sql).ok, f"expected BLOCKED: {sql!r}"
