"""Web-app settings (env-driven).

Kept separate from ``src/config.py`` (the reused agent config) so the agent stays
portable. Everything here is overridable via environment variables; in Kubernetes
the sensitive values (``MONGODB_URI``, ``SECRET_KEY``, ``FIREWORKS_API_KEY``) come
from a Secret, never baked into the image.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

# --- MongoDB: the app's own system-of-record (users / uploads / history) -------
# Per the exercise, the connection string is injected as a Kubernetes env var.
MONGODB_URI = os.getenv("MONGODB_URI", "mongodb://localhost:27017")
MONGO_DB_NAME = os.getenv("MONGO_DB_NAME", "text2sql")
MONGO_TIMEOUT_MS = int(os.getenv("MONGO_TIMEOUT_MS", "3000"))

# --- Auth ----------------------------------------------------------------------
# NOTE: the default is a dev placeholder; a real deploy MUST override SECRET_KEY
# from a Secret. We warn loudly at startup if it is left as the default.
SECRET_KEY = os.getenv("SECRET_KEY", "dev-only-change-me")
JWT_ALG = "HS256"
JWT_TTL_MIN = int(os.getenv("JWT_TTL_MIN", "60"))
IS_DEFAULT_SECRET = SECRET_KEY == "dev-only-change-me"

# --- Uploaded .db handling (see storage.py for the hardening rationale) ---------
UPLOAD_DIR = Path(os.getenv("UPLOAD_DIR", "uploads"))
# Cap upload size to bound disk use and parser exposure (default 50 MiB).
MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_BYTES", str(50 * 1024 * 1024)))
# Wall-clock cap for a single query against an uploaded DB (DoS guard).
QUERY_TIMEOUT_S = float(os.getenv("QUERY_TIMEOUT_S", "5"))
# How many prior turns to replay into the agent for follow-up questions.
HISTORY_TURNS = int(os.getenv("HISTORY_TURNS", "4"))

# Convenience: a bundled sample DB users can try immediately.
SAMPLE_DB_PATH = os.getenv("SAMPLE_DB_PATH", "data/Chinook.db")
