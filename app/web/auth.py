"""Authentication: bcrypt password hashing + JWT session cookie.

Mirrors the pattern in the provided Tasky app (bcrypt + a signed token in a
cookie) so it is familiar and easy to reason about on the call.
"""

from __future__ import annotations

from datetime import timedelta
from typing import Optional

import bcrypt
from fastapi import Cookie, HTTPException, status
from jose import JWTError, jwt

from . import mongo, settings

COOKIE_NAME = "session"


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode(), hashed.encode())
    except (ValueError, TypeError):
        return False


def create_token(user_id: str, email: str) -> str:
    expire = mongo.now() + timedelta(minutes=settings.JWT_TTL_MIN)
    payload = {"sub": user_id, "email": email, "exp": expire}
    return jwt.encode(payload, settings.SECRET_KEY, algorithm=settings.JWT_ALG)


def _decode(token: str) -> dict:
    return jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.JWT_ALG])


def current_user(session: Optional[str] = Cookie(default=None)) -> dict:
    """FastAPI dependency: resolve the session cookie to a user, or 401."""
    if not session:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "not authenticated")
    try:
        claims = _decode(session)
    except JWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or expired session")
    return {"id": claims["sub"], "email": claims.get("email", "")}
