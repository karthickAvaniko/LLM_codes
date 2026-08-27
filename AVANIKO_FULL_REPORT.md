# Avaniko AI Platform — Full A-to-Z Technical Report

**Date:** 2026-06-18  **Owner:** surya.inbasagaran@avaniko.com
**Public URL:** `https://s2f1q59mb9tg9r-7778.proxy.runpod.net`
**Model (public name):** `avaniko-ai`  (engine: Qwen3.6-35B, served internally as `qwen3.6-35b`)

This document explains every part of the platform: the architecture, every service,
every function in the gateway, why each exists, and how the whole thing works together.

---

## PART 1 — WHAT THIS PLATFORM IS

A self-hosted, OpenAI-compatible AI platform on a private GPU server. One API key gives
access to chat, reasoning, coding, classification, document understanding (PDF / image /
Word / Excel), inline-image OCR, web search, and multi-document RAG — the same way
Gemini and OpenAI work. An admin console manages users and keys; a chat UI is included.

---

## PART 2 — ARCHITECTURE (5 services on one RunPod pod)

```
Internet → RunPod proxy → :7778 GATEWAY (public)
                              ├─ :7777 vLLM        (localhost)  LLM on GPU
                              ├─ :7779 Embeddings  (localhost)  RAG vectors
                              ├─ :7780 OCR         (localhost)  PaddleOCR, isolated
                              └─ :3306 MySQL       (localhost)  api_keys / users / sessions
                           + daily backup loop → /workspace/backups
```

- **Only port 7778 is public.** vLLM/OCR/Embeddings/MySQL are localhost-only (security).
- Everything lives under `/workspace` (persistent volume) — survives pod stop/start.
- Boot everything: `bash /workspace/start_all.sh`.

| Service | File | Why it exists |
|---|---|---|
| Gateway | `gateway/main.py` | The product: auth, routing, all endpoints, UI |
| vLLM | (start_all.sh) | Runs the 35B model on the GPU with batching |
| Embeddings | `embed_server.py` | Turns text into vectors for RAG search (MiniLM, CPU) |
| OCR | `ocr_server.py` | Reads scanned/image text; isolated so a crash can't take down the gateway |
| MySQL | (MariaDB) | System of record for keys, users, sessions |

---

## PART 3 — DATA MODEL (MySQL: database `avaniko`)

- **api_keys** — `key_hash` (SHA-256, primary key), id, name, email (owner), created,
  active, expires, rpm_limit, daily_limit, requests, tokens_in, tokens_out, last_used,
  self_service. *Raw keys are never stored — only hashes.*
- **users** — id, email (login), name, pw_hash (PBKDF2), created, active.
- **sessions** — token_hash, email, created, expires. *Login sessions, survive restart.*

---

## PART 4 — THE GATEWAY, FUNCTION BY FUNCTION (why each exists)

### 4.1 Logging & utilities
- **`_trunc`** — shortens long strings before logging, so customer content is stored as
  previews (privacy + disk control).
- **`_append_jsonl`** — appends one JSON line to a log file; rotates at 200 MB. Used for
  the access log (every request) and content log (questions/answers).
- **`_client_ip`** — gets the real caller IP (handles proxy `x-forwarded-for`).
- **`_now_iso`** — current timestamp string, used everywhere for created/last_used.

### 4.2 Database & master key
- **`_load_api_key`** — loads (or generates once) the master admin key from
  `gateway/.api_key`. This is the root key for the old `/keys` admin console.
- **`_mysql_password`** — reads the MySQL password from `gateway/.mysql_env`.
- **`_db`** — opens a MySQL connection (autocommit, dict rows). Used by every DB call.

### 4.3 API key store (the heart of access control)
- **`_hash_key`** — SHA-256 of a raw key. Keys are matched and stored by hash only.
- **`_row_to_info` / `_load_keys`** — load all keys from MySQL into an in-memory cache
  (`API_KEYS`) for fast per-request auth; migrates a legacy `keys.json` once if present.
- **`_persist_keys` / `_save_keys`** — write the in-memory cache back to MySQL (upsert).
  Called on create/revoke/delete and flushed periodically.
- **`_find_by_id`** — look up a key by its short public id (e.g. `ak-1e0a723a`).
- **`_key_summary`** — the safe public view of a key (no secret) for the console/tables.
- **`_my_keys`** — all keys belonging to one user email (for the user dashboard).

### 4.4 Rate limiting & token accounting
- **`_prune`** — drops timestamps older than a window (used by the limiters).
- **`_check_rate_limit`** — enforces per-key requests/minute and requests/day; returns an
  error message if over limit (→ HTTP 429). Protects the GPU from one key flooding it.
- **`_auth_fail_blocked`** — per-IP brute-force lock: >20 failed auths/min → blocked.
- **`_resolve_key`** — THE auth function: validates a token, checks active + rate limit,
  increments usage, returns (user, key_hash, error). Keys never expire — only revoke
  (active=0) disables them.
- **`_record_tokens`** — adds prompt/completion token counts to a key (billing-ready usage).
- **`_persist_loop`** — background task: flushes usage to MySQL every 15s and prunes idle
  rate-limit memory hourly so memory never grows.

### 4.5 Middleware — `require_api_key`
The gate every request passes through. It:
1. Lets public paths (UI pages, health, login) through.
2. For `/me/*` and `/admin-api/*` → checks a **session token** (console users/admin).
3. For everything else → checks an **API key** via `_resolve_key`.
4. Returns clean 401/403/429 on failure (with brute-force lockout).
5. Wraps the handler so any crash becomes a clean JSON error (never a raw 500), and
   a context overflow becomes a clear 422 instead of breaking.
6. Logs every request to the access log.

### 4.6 OCR & file text extraction
- **`ocr_image`** — sends image bytes to the isolated OCR service (port 7780) and returns
  text; returns "" on failure so the pipeline degrades gracefully.
- **`extract_pages`** — extracts text page-by-page from PDF (OCR for scanned pages),
  images, Word (.docx), Excel (.xlsx), and plain text/CSV. The universal document reader.
- **`extract_text`** — joins all pages into one string (convenience).
- **`_warm_ocr`** — no-op now (OCR lives in its own service).

### 4.7 LLM calls & the document engine
- **`ContextOverflow`** — custom exception raised when a prompt exceeds the 32k window;
  triggers the map-reduce fallback.
- **`_llm`** — one non-streaming call to vLLM; records tokens; raises `ContextOverflow`
  on overflow. The base building block for document answering.
- **`_llm_sse`** — streaming version (Claude-style live tokens) for RAG answers.
- **`_pages_text`** — labels pages (`[Page N]`) and joins them for a prompt.
- **`_chunk_pages`** — groups pages into ≤35k-char chunks on page boundaries (map step).
- **`_doc_messages` / `_reduce_messages`** — build the prompts for the map and reduce
  steps; instruct the model to answer in the format asked (prose vs JSON).
- **`_map_chunks`** — answers the question against every chunk in parallel (the "map").
- **`answer_document`** — the strategy chooser: small doc → one call; big doc →
  map-reduce with hierarchical merge (handles 500+ pages). Returns (answer, strategy, calls).

### 4.8 RAG (search across many documents)
- **`_embed`** — turns text into vectors via the embedding service.
- **`_rag_chunks`** — splits a document's pages into ~1,800-char chunks for indexing.
- **`_ensure_index`** — builds (and caches on disk) the vector index for a file.
- **`rag_retrieve`** — embeds the question, finds the top matching chunks across all the
  user's files (cosine similarity), returns them with file/page sources.
- **`_rag_messages`** — builds the final prompt from only the top chunks, so the prompt
  size stays constant no matter how many documents exist (token-safe).

### 4.9 Context-limit protection (so the token error never happens)
- **`_ctx_char_budget`** — computes how many input characters safely fit alongside the
  requested output, budgeting against the 32k window conservatively.
- **`_fit_messages`** — trims oversized history / one giant message to fit the budget
  (keeps system + newest turns).
- **`_vllm_post`** — non-streaming call that auto-shrinks the prompt and retries (up to
  4×) if the model still reports overflow.
- **`_resolve_images`** — converts OpenAI vision `image_url` parts into OCR'd text, so a
  text-only model can still "read" images/invoices/screenshots sent inline.

### 4.10 Smart routing (Gemini/GPT-style "just works")
- **`_detect_task`** — the model classifies its own task (chat / reasoning / coding /
  extraction / classification) so the right temperature + thinking-mode are applied
  automatically when the client sends `task:"auto"` (the default).
- **`TASK_PRESETS`** — the tuned settings per task type.
- **`_web_search_sync` / `_needs_web` / `_web_context`** — web search: the model decides
  if a question needs live internet data, the gateway searches (DuckDuckGo), and feeds
  the results back with [1][2] citations.
- **`_merge_system`** — merges multiple system messages into one (the model template
  requires a single system message at the start).

### 4.11 User accounts & sessions
- **`_pw_hash` / `_pw_verify`** — password hashing (PBKDF2, 200k iterations).
- **`_session_create` / `_session_email` / `_session_destroy`** — issue, validate, and
  revoke login session tokens (7-day, stored hashed in MySQL, survive restart).
- **`_user_get`** — fetch a user by email.

---

## PART 5 — ENDPOINTS (the public API surface)

### Auth & console
- `GET /` chat UI · `GET /console` unified console · `GET /admin` (same console) ·
  `GET /keys` legacy master-key console · `GET /getkey` (public signup, currently closed)
- `POST /auth/signin` — one login for admin + users (auto-detects which)
- `POST /auth/admin-login`, `POST /auth/login` — role-specific logins
- `POST /auth/register` — disabled (admin creates users)
- `POST /auth/logout`

### User (session) — `/me/*`
- `GET /me/keys` — the user's keys · `GET /me/usage` — their rolled-up usage

### Admin (session) — `/admin-api/*`
- `GET/POST /admin-api/users`, `DELETE /admin-api/users/{email}` — manage users
- `GET/POST /admin-api/keys`, `DELETE /admin-api/keys/{id}` (revoke),
  `POST /admin-api/keys/{id}/delete` (permanent) — manage keys (always tied to a user)

### Core AI API (API key) — OpenAI-compatible
- `POST /v1/chat/completions` — chat/reasoning/coding (streaming, auto-task, web search,
  inline-image OCR, context-safe)
- `GET /v1/models`, `GET /v1/usage`
- `POST /v1/files`, `GET /v1/files`, `GET/DELETE /v1/files/{id}` — file storage
- `POST /v1/files/{id}/ask` — ask about one document
- `POST /v1/ask` — RAG across all documents
- `POST /v1/extract` — up to 20 files in one request → JSON per file
- `POST /chat` — UI helper (date-aware, streaming) · `POST /files/ask` — UI file chat
- `GET /health`

### Legacy admin (master key) — `/admin/keys*`
Kept for operator use; the console uses `/admin-api/*`.

---

## PART 6 — KEY DESIGN DECISIONS (why it's built this way)

1. **Stateless API** (like OpenAI/Gemini) — server stores no conversation; clients send
   messages each call. Simpler, scalable, no per-session memory leaks.
2. **Keys stored hashed, shown once** — a DB leak can't expose keys.
3. **In-memory key cache + MySQL** — auth is instant (memory), MySQL is the durable record.
4. **OCR isolated in its own process** — PaddleOCR can segfault; isolation + auto-restart
   keeps the gateway rock-solid. Runs single-threaded (multi-thread segfaults Paddle).
5. **Keys never expire** — only an explicit revoke/delete disables a key (your requirement).
6. **Admin-controlled** — only the admin creates users and keys; every key belongs to a user.
7. **Context-overflow impossible** — 6 layers (budget, retry, history-trim, image-OCR,
   map-reduce, RAG) ensure the token error never reaches a user.
8. **White-labeled** — customers see only `avaniko-ai`; the underlying engine is hidden.

---

## PART 7 — CAPACITY & LIMITS (measured)

- Context window 32,768 tokens; output cap 8,192.
- Generation ~73 tok/s single; ~418 tok/s at 8 parallel users.
- 8 requests generate simultaneously; extras queue (never fail).
- Unlimited active keys; each defaults to 60 req/min, 5,000 req/day.
- Files: 50 MB each, 200 per key. Batch: 20 files/request.
- Realistic: 200–400 active chat users on the single GPU.

---

## PART 8 — OPERATIONS

- Start/restart everything: `bash /workspace/start_all.sh`
- Health: `curl http://localhost:7778/health`
- Master admin key: `cat /workspace/gateway/.api_key`
- Admin console login: `Avaniko@admin.in` / `Avan@123` at `/console`
- Inspect data: `mysql avaniko -e "SELECT name,email,requests FROM api_keys;"`
- Daily backups: `/workspace/backups/` (14-day retention, includes MySQL dump)
- Logs: `/workspace/logs/` (access.jsonl, requests.jsonl, gateway_app.log, vllm.log,
  ocr_v2.log, embed.log, mysql.log, backup.log)

---

## PART 9 — COMPANION DOCUMENTS

- `DOCUMENTATION.md` — API usage reference (endpoints, examples, limits)
- `RUNPOD_DEPLOYMENT.md` — A-to-Z deploy on a fresh pod
- `TOKEN_LIMIT_SOLUTION.md` — the context-limit solution in depth
- `API_GUIDE.md` — quick copy-paste usage
- `AVANIKO_PROJECT_REPORT_TAMIL.md` — Tamil overview

---

## PART 10 — RECOMMENDED NEXT STEPS

1. Move the admin password out of plaintext into an environment variable / hash.
2. Copy daily backups off-pod (S3 / Google Drive) — the one real data-loss risk.
3. Custom domain `api.avaniko.com` via Cloudflare so the URL never changes.
4. (Optional) Resume the modular folder refactor of `main.py` (parked).
5. (Optional, when scanned-doc volume grows) GPU OCR for 5–10× faster extraction.
6. Payment gateway — only when moving from internal to external customers.
