"""
core.py — shared plumbing for the Avaniko gateway.

Everything other modules depend on lives here: config, logging, the MySQL
connection, the API-key store (+ in-memory cache and rate limiting), user
accounts/sessions, and file-metadata storage. Other modules do
`from app import core` and reference `core.<name>`, so the mutable global
state (API_KEYS, sessions, rate-limit windows) is shared correctly.
"""
import asyncio
import hashlib
import json
import logging
import os
import re
import secrets
import time
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path

import pymysql
from fastapi import Request

# ── Config ────────────────────────────────────────────────
VLLM_URL     = "http://localhost:7777"
EMBED_URL    = "http://127.0.0.1:7779"
OCR_URL      = "http://127.0.0.1:7780"
MODEL        = "qwen3.6-35b"   # internal — what vLLM serves
PUBLIC_MODEL = "avaniko-ai"    # white-label name customers see everywhere
STATIC       = Path(__file__).resolve().parent.parent / "static"
GATEWAY_DIR  = Path(__file__).resolve().parent.parent

MAX_TOKENS_CAP      = 8192    # hard cap on max_tokens per request
DEFAULT_RPM_LIMIT   = 60      # requests per minute per key
DEFAULT_DAILY_LIMIT = 5000    # requests per UTC day per key

# ── Logging ───────────────────────────────────────────────
LOG_DIR = Path("/workspace/logs")
LOG_DIR.mkdir(exist_ok=True)
logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
log = logging.getLogger("gateway")
_fh = RotatingFileHandler(LOG_DIR / "gateway_app.log", maxBytes=50_000_000, backupCount=5)
_fh.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s"))
logging.getLogger().addHandler(_fh)

# ── Persistent JSONL logs ─────────────────────────────────
ACCESS_LOG    = LOG_DIR / "access.jsonl"    # every HTTP request, incl. 401s
CONTENT_LOG   = LOG_DIR / "requests.jsonl"  # questions/answers/OCR previews
LOG_MAX_BYTES = 200_000_000                 # rotate at 200 MB
LOG_STR_LIMIT = 1000                        # store previews, not full content

def _trunc(value):
    if isinstance(value, str) and len(value) > LOG_STR_LIMIT:
        return value[:LOG_STR_LIMIT] + f"…[truncated {len(value)} chars]"
    if isinstance(value, list):
        return [_trunc(v) for v in value]
    if isinstance(value, dict):
        return {k: _trunc(v) for k, v in value.items()}
    return value

def _append_jsonl(path: Path, record: dict):
    record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    try:
        if path.exists() and path.stat().st_size > LOG_MAX_BYTES:
            path.replace(path.with_suffix(path.suffix + ".1"))
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(_trunc(record), ensure_ascii=False) + "\n")
    except Exception as e:
        log.error(f"LOGWRITE failed | {path.name} | {e}")

def _client_ip(request: Request) -> str:
    return request.headers.get("x-forwarded-for", "").split(",")[0].strip() \
        or (request.client.host if request.client else "?")

def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")

class ContextOverflow(Exception):
    """vLLM rejected the request: prompt too long for the 32k context."""

# ── Master admin key ──────────────────────────────────────
_KEY_FILE = GATEWAY_DIR / ".api_key"

def _load_api_key() -> str:
    key = os.environ.get("AVANIKO_API_KEY", "").strip()
    if key:
        return key
    if _KEY_FILE.exists():
        key = _KEY_FILE.read_text().strip()
        if key:
            return key
    key = "ak-" + secrets.token_hex(24)
    _KEY_FILE.write_text(key)
    _KEY_FILE.chmod(0o600)
    log.info("API KEY generated and saved to %s", _KEY_FILE)
    return key

API_KEY = _load_api_key()

# ── MySQL ─────────────────────────────────────────────────
KEYS_FILE = GATEWAY_DIR / "keys.json"  # legacy — migrated to MySQL

def _mysql_password() -> str:
    env = GATEWAY_DIR / ".mysql_env"
    for line in env.read_text().splitlines():
        if line.startswith("MYSQL_PASSWORD="):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("MYSQL_PASSWORD missing in gateway/.mysql_env")

MYSQL_PASSWORD = _mysql_password()

def _db():
    return pymysql.connect(host="127.0.0.1", user="avaniko",
                           password=MYSQL_PASSWORD, database="avaniko",
                           autocommit=True, cursorclass=pymysql.cursors.DictCursor)

# ── API key store (MySQL-backed, in-memory cache) ─────────
_KEY_COLS = ("id", "name", "email", "created", "active", "expires", "rpm_limit",
             "daily_limit", "requests", "tokens_in", "tokens_out", "last_used",
             "self_service")

def _hash_key(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()

def _row_to_info(row: dict) -> dict:
    info = {k: row[k] for k in _KEY_COLS}
    info["active"]       = bool(info["active"])
    info["self_service"] = bool(info.get("self_service"))
    return info

def _load_keys() -> dict:
    """Load all keys from MySQL; one-time migrate legacy keys.json if present."""
    with _db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM api_keys")
        keys = {row["key_hash"]: _row_to_info(row) for row in cur.fetchall()}
    if not keys and KEYS_FILE.exists():
        try:
            data = json.loads(KEYS_FILE.read_text())
            legacy = data.get("keys", data) if isinstance(data, dict) else {}
            for h, info in legacy.items():
                if not isinstance(info, dict):
                    continue
                keys[h] = {c: info.get(c) for c in _KEY_COLS}
                keys[h].setdefault("rpm_limit", DEFAULT_RPM_LIMIT)
                keys[h]["active"] = bool(info.get("active"))
                keys[h]["self_service"] = bool(info.get("self_service"))
            if keys:
                _persist_keys(keys)
                KEYS_FILE.rename(KEYS_FILE.with_suffix(".json.migrated"))
                log.info("keys.json migrated to MySQL (%d keys)", len(keys))
        except Exception as e:
            log.error(f"keys.json migration failed: {e}")
    return keys

def _persist_keys(keys: dict):
    cols = ", ".join(("key_hash",) + _KEY_COLS)
    ph   = ", ".join(["%s"] * (len(_KEY_COLS) + 1))
    upd  = ", ".join(f"{c}=VALUES({c})" for c in _KEY_COLS)
    sql  = f"INSERT INTO api_keys ({cols}) VALUES ({ph}) ON DUPLICATE KEY UPDATE {upd}"
    rows = [(h, *[info.get(c) for c in _KEY_COLS]) for h, info in keys.items()]
    with _db() as conn, conn.cursor() as cur:
        cur.executemany(sql, rows)

API_KEYS = _load_keys()       # {sha256_hash: {metadata}} — in-memory cache
_keys_dirty = False           # usage counters pending flush to MySQL

def _save_keys():
    """Flush the in-memory cache to MySQL (upsert; table is small)."""
    global _keys_dirty
    try:
        if API_KEYS:
            _persist_keys(API_KEYS)
        _keys_dirty = False
    except Exception as e:
        log.error(f"MySQL persist failed (in-memory cache still serving): {e}")

def mark_dirty():
    global _keys_dirty
    _keys_dirty = True

def is_dirty() -> bool:
    return _keys_dirty

# ── Rate limiting ─────────────────────────────────────────
_rpm_windows   = defaultdict(deque)   # key_hash -> timestamps (last minute)
_daily_counts  = {}                   # key_hash -> [utc_date_str, count]
_auth_fails    = defaultdict(deque)   # ip -> failed auth timestamps
_signups_by_ip = defaultdict(deque)   # ip -> self-service signup timestamps
AUTH_FAIL_LIMIT = 20

def _prune(window: deque, horizon: float):
    while window and window[0] < horizon:
        window.popleft()

def _check_rate_limit(key_hash: str, info: dict) -> str | None:
    now = time.time()
    win = _rpm_windows[key_hash]
    _prune(win, now - 60)
    if len(win) >= info.get("rpm_limit", DEFAULT_RPM_LIMIT):
        return f"Rate limit exceeded: {info.get('rpm_limit', DEFAULT_RPM_LIMIT)} requests/minute. Retry shortly."
    today = time.strftime("%Y-%m-%d", time.gmtime())
    day = _daily_counts.get(key_hash)
    if day is None or day[0] != today:
        day = _daily_counts[key_hash] = [today, 0]
    if day[1] >= info.get("daily_limit", DEFAULT_DAILY_LIMIT):
        return f"Daily quota exceeded: {info.get('daily_limit', DEFAULT_DAILY_LIMIT)} requests/day. Resets at midnight UTC."
    win.append(now)
    day[1] += 1
    return None

def _auth_fail_blocked(ip: str) -> bool:
    now = time.time()
    win = _auth_fails[ip]
    _prune(win, now - 60)
    win.append(now)
    return len(win) > AUTH_FAIL_LIMIT

def _resolve_key(token: str) -> tuple[str, str | None, str | None]:
    """Validate token. Returns (user_name|'', key_hash|None, error_message|None)."""
    global _keys_dirty
    if secrets.compare_digest(token, API_KEY):
        return "admin", None, None
    key_hash = _hash_key(token)
    info = API_KEYS.get(key_hash)
    if not info or not info.get("active"):
        return "", None, "Invalid or missing API key. Send header: Authorization: Bearer <key>"
    if info.get("expires") and info["expires"] < _now_iso():
        return "", None, "API key expired. Contact support for a new key."
    limit_err = _check_rate_limit(key_hash, info)
    if limit_err:
        return info.get("name", "user"), key_hash, limit_err
    info["requests"] = info.get("requests", 0) + 1
    info["last_used"] = _now_iso()
    _keys_dirty = True
    return info.get("name", "user"), key_hash, None

def _record_tokens(key_hash: str | None, usage: dict | None):
    global _keys_dirty
    if not key_hash or not usage:
        return
    info = API_KEYS.get(key_hash)
    if info:
        info["tokens_in"]  = info.get("tokens_in", 0)  + (usage.get("prompt_tokens") or 0)
        info["tokens_out"] = info.get("tokens_out", 0) + (usage.get("completion_tokens") or 0)
        _keys_dirty = True

async def _persist_loop():
    """Flush dirty usage counters every 15s; prune rate-limit memory hourly."""
    tick = 0
    while True:
        await asyncio.sleep(15)
        tick += 1
        if _keys_dirty:
            try:
                _save_keys()
            except Exception as e:
                log.error(f"keys persist failed: {e}")
        if tick % 240 == 0:
            horizon = time.time() - 3600
            for d in (_rpm_windows, _auth_fails, _signups_by_ip):
                for k in [k for k, w in d.items() if not w or w[-1] < horizon]:
                    del d[k]

def _find_by_id(key_id: str):
    by_hash = API_KEYS.get(_hash_key(key_id))
    if by_hash:
        return _hash_key(key_id), by_hash
    for h, info in API_KEYS.items():
        if info.get("id") == key_id:
            return h, info
    return None, None

def _key_summary(info: dict) -> dict:
    return {"id": info.get("id"), "name": info["name"], "email": info.get("email"),
            "created": info["created"],
            "active": info["active"], "expires": info.get("expires"),
            "rpm_limit": info.get("rpm_limit"), "daily_limit": info.get("daily_limit"),
            "requests": info.get("requests", 0),
            "tokens_in": info.get("tokens_in", 0), "tokens_out": info.get("tokens_out", 0),
            "last_used": info.get("last_used")}

def _my_keys(email: str) -> list[dict]:
    return [dict(_key_summary(v)) for v in API_KEYS.values() if v.get("email") == email]

# ── User accounts (@avaniko.com only) ─────────────────────
ALLOWED_EMAIL_RE  = re.compile(r"^[A-Za-z0-9._%+-]+@avaniko\.com$", re.I)
SESSION_DAYS      = 7
MAX_KEYS_PER_USER = 3
_SESSIONS: dict = {}   # token_hash -> (email, expires_epoch)

def _pw_hash(password: str, salt: str | None = None) -> str:
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000).hex()
    return f"{salt}${h}"

def _pw_verify(password: str, stored: str) -> bool:
    try:
        salt, _ = stored.split("$", 1)
        return secrets.compare_digest(_pw_hash(password, salt), stored)
    except Exception:
        return False

def _session_create(email: str) -> str:
    token = "st-" + secrets.token_hex(24)
    th, exp = _hash_key(token), time.time() + SESSION_DAYS * 86_400
    _SESSIONS[th] = (email, exp)
    try:
        with _db() as conn, conn.cursor() as cur:
            cur.execute("INSERT INTO sessions (token_hash, email, created, expires) "
                        "VALUES (%s,%s,%s,%s)", (th, email, _now_iso(), exp))
    except Exception as e:
        log.error(f"session persist failed: {e}")
    return token

def _session_email(token: str) -> str | None:
    if not token.startswith("st-"):
        return None
    th = _hash_key(token)
    hit = _SESSIONS.get(th)
    if hit is None:
        try:
            with _db() as conn, conn.cursor() as cur:
                cur.execute("SELECT email, expires FROM sessions WHERE token_hash=%s", (th,))
                row = cur.fetchone()
            hit = (row["email"], row["expires"]) if row else ("", 0)
        except Exception:
            hit = ("", 0)
        _SESSIONS[th] = hit
    email, exp = hit
    return email if email and exp > time.time() else None

def _session_destroy(token: str):
    th = _hash_key(token)
    _SESSIONS.pop(th, None)
    try:
        with _db() as conn, conn.cursor() as cur:
            cur.execute("DELETE FROM sessions WHERE token_hash=%s", (th,))
    except Exception:
        pass

def _user_get(email: str) -> dict | None:
    with _db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM users WHERE email=%s", (email,))
        return cur.fetchone()

# ── Self-service signup config ────────────────────────────
TRIAL_RPM    = 10
TRIAL_DAILY  = 250
TRIAL_DAYS   = 30
SIGNUP_PER_IP_PER_DAY = 2
SELF_SIGNUP_OPEN = os.environ.get("AVANIKO_SELF_SIGNUP", "0") == "1"

# ── File-metadata storage ─────────────────────────────────
FILES_DIR = GATEWAY_DIR / "files"
FILES_DIR.mkdir(exist_ok=True)
MAX_FILE_MB       = 50
MAX_FILES_PER_KEY = 200
MAX_BATCH_FILES   = 20
ALLOWED_EXTS = {"pdf", "png", "jpg", "jpeg", "webp", "bmp", "tiff",
                "txt", "csv", "md", "json", "html", "docx", "xlsx", "xls"}

def _file_owner(request: Request) -> str:
    return getattr(request.state, "key_hash", None) or "admin"

def _meta_path(fid: str) -> Path:  return FILES_DIR / f"{fid}.json"
def _pages_path(fid: str) -> Path: return FILES_DIR / f"{fid}.pages.json"

def _load_meta(fid: str) -> dict | None:
    p = _meta_path(fid)
    if not p.exists() or not fid.startswith("file-"):
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        return None

def _save_meta(meta: dict):
    _meta_path(meta["id"]).write_text(json.dumps(meta, ensure_ascii=False))

def _owner_metas(owner: str) -> list[dict]:
    metas = []
    for p in FILES_DIR.glob("file-*.json"):
        if p.name.endswith(".pages.json"):
            continue
        try:
            m = json.loads(p.read_text())
            if owner == "admin" or m.get("owner") == owner:
                metas.append(m)
        except Exception:
            pass
    return sorted(metas, key=lambda m: m.get("created", ""), reverse=True)

def _meta_public(meta: dict) -> dict:
    return {k: meta[k] for k in
            ("id", "filename", "bytes", "pages", "chars", "status", "created", "error")
            if k in meta}

# Paths reachable without a key (UI shells + health + public auth)
PUBLIC_PATHS = {"/", "/health", "/favicon.ico", "/keys", "/getkey", "/signup/key",
                "/console", "/auth/register", "/auth/login"}
