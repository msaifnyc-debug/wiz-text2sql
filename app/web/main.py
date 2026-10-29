"""Text-to-SQL web app (FastAPI).

Routes
  GET  /            -> login / signup page
  GET  /console     -> the query console (auth required)
  POST /signup      -> create account, set session cookie
  POST /login       -> authenticate, set session cookie
  POST /logout      -> clear session cookie
  POST /api/upload  -> upload a .db (auth) -> hardened validation + registry
  GET  /api/dbs     -> list the caller's uploaded databases
  POST /api/ask     -> natural-language question -> SQL + results (auth)
  GET  /api/history -> recent query history (auth)
  GET  /healthz     -> liveness (+ mongo ping, api-key presence)

Run:  uvicorn web.main:app --host 0.0.0.0 --port 8080
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, EmailStr, Field
from pymongo.errors import DuplicateKeyError

from src import config

from . import auth, mongo, settings
from .agent_service import AgentUnavailable, answer_question
from .storage import UploadError, validate_and_store

log = logging.getLogger("text2sql")
logging.basicConfig(level=logging.INFO)

BASE = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE / "templates"))

app = FastAPI(title="Text-to-SQL", docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=str(BASE / "static")), name="static")


@app.on_event("startup")
def _startup() -> None:
    settings.UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    try:
        mongo.ensure_indexes()
    except Exception as e:  # don't crash if Mongo is briefly unavailable at boot
        log.warning("could not create Mongo indexes yet: %s", e)
    if settings.IS_DEFAULT_SECRET:
        log.warning("SECRET_KEY is the dev default - set it from a Secret in any real deploy")
    if not config.has_api_key():
        log.warning("FIREWORKS_API_KEY not set - /api/ask will return a clear error until it is")


# --- request models ------------------------------------------------------------
class SignupIn(BaseModel):
    email: EmailStr
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=8, max_length=200)


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class AskIn(BaseModel):
    db_id: str
    question: str = Field(min_length=1, max_length=2000)


def _set_session(resp: JSONResponse, user_id: str, email: str) -> None:
    token = auth.create_token(user_id, email)
    resp.set_cookie(
        auth.COOKIE_NAME, token,
        httponly=True, samesite="lax", max_age=settings.JWT_TTL_MIN * 60,
    )


# --- pages ---------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse("login.html", {"request": request})


@app.get("/console", response_class=HTMLResponse)
def console(request: Request):
    return templates.TemplateResponse("console.html", {"request": request})


# --- auth ----------------------------------------------------------------------
@app.post("/signup")
def signup(body: SignupIn):
    doc = {
        "email": body.email.lower(),
        "username": body.username,
        "password_hash": auth.hash_password(body.password),
        "created_at": mongo.now(),
    }
    try:
        res = mongo.users().insert_one(doc)
    except DuplicateKeyError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "an account with this email already exists")
    out = JSONResponse({"ok": True})
    _set_session(out, str(res.inserted_id), body.email.lower())
    return out


@app.post("/login")
def login(body: LoginIn):
    user = mongo.users().find_one({"email": body.email.lower()})
    if not user or not auth.verify_password(body.password, user["password_hash"]):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "email or password is incorrect")
    out = JSONResponse({"ok": True})
    _set_session(out, str(user["_id"]), user["email"])
    return out


@app.post("/logout")
def logout():
    out = JSONResponse({"ok": True})
    out.delete_cookie(auth.COOKIE_NAME)
    return out


# --- API -----------------------------------------------------------------------
@app.post("/api/upload")
async def upload(user=Depends(auth.current_user), file: UploadFile = File(...)):
    try:
        stored = await run_in_threadpool(
            validate_and_store, user["id"], file.filename or "upload.db", file.file
        )
    except UploadError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(e))

    mongo.databases().insert_one(
        {
            "db_id": stored.db_id,
            "owner": user["id"],
            "filename": stored.filename,
            "sha256": stored.sha256,
            "size_bytes": stored.size_bytes,
            "tables": stored.tables,
            "created_at": mongo.now(),
        }
    )
    return {
        "db_id": stored.db_id,
        "filename": stored.filename,
        "size_bytes": stored.size_bytes,
        "tables": stored.tables,
    }


@app.get("/api/dbs")
def list_dbs(user=Depends(auth.current_user)):
    cur = mongo.databases().find({"owner": user["id"]}).sort("created_at", -1)
    return {
        "databases": [
            {
                "db_id": d["db_id"],
                "filename": d["filename"],
                "size_bytes": d["size_bytes"],
                "tables": d.get("tables", []),
                "created_at": d["created_at"].isoformat(),
            }
            for d in cur
        ]
    }


@app.post("/api/ask")
async def ask(body: AskIn, user=Depends(auth.current_user)):
    db_doc = mongo.databases().find_one({"db_id": body.db_id, "owner": user["id"]})
    if not db_doc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "database not found")
    try:
        result = await run_in_threadpool(answer_question, user["id"], db_doc, body.question)
    except AgentUnavailable as e:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(e))
    return result


@app.get("/api/history")
def get_history(user=Depends(auth.current_user), limit: int = 20):
    cur = (
        mongo.history()
        .find({"owner": user["id"]})
        .sort("created_at", -1)
        .limit(min(limit, 100))
    )
    return {
        "history": [
            {
                "question": h["question"],
                "sql": h.get("sql"),
                "success": h["success"],
                "latency_s": h.get("latency_s"),
                "created_at": h["created_at"].isoformat(),
            }
            for h in cur
        ]
    }


# --- health --------------------------------------------------------------------
@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    ok = mongo.ping()
    code = status.HTTP_200_OK if ok else status.HTTP_503_SERVICE_UNAVAILABLE
    return JSONResponse(
        {"mongo": ok, "fireworks_key": config.has_api_key()}, status_code=code
    )
