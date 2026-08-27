# Avaniko AI Platform — Current State (A to Z)
> Last updated: 2026-06-09 | Analysed by Claude Code

---

## 1. Architecture Overview

```
Developer / Client App
        │
        │  https://api.avaniko.com  (NOT YET DEPLOYED)
        ▼
┌──────────────────────────────────────┐
│   avaniko-platform  (IIS / VPS)      │  ← Public-facing API + Dashboard
│   FastAPI + PostgreSQL + pgvector    │     User accounts, API keys, billing
│   React Frontend (Vite + Tailwind)   │
└─────────────────┬────────────────────┘
                  │ Internal (RunPod URL hidden)
                  ▼
┌──────────────────────────────────────┐
│   production/  (RunPod Pod)          │  ← Private AI backend  ✅ RUNNING
│   FastAPI gateway  → port 2222       │
│   vLLM server      → port 1111       │
│   MySQL            → port 3306       │
└──────────────────────────────────────┘
                  ▲
                  │ (direct access for testing only)
┌──────────────────────────────────────┐
│   api-key-tester/  (RunPod port 2222)│  ← Dev tester UI  ✅ RUNNING
│   Flask + BM25 + map-reduce          │     Upload files, chat, streaming
└──────────────────────────────────────┘
```

---

## 2. RunPod Port Map

| Port | Service | Access | URL |
|------|---------|--------|-----|
| **1111** | vLLM — Qwen3.6-35B GPTQ Int4 (AI model server) | Internal only | `http://localhost:1111` |
| **2222** | Production FastAPI Gateway (public API) | Public | `https://s2f1q59mb9tg9r-2222.proxy.runpod.net` |
| **7777** | Spare / available | — | — |
| **7778** | Spare / available | — | — |
| **8888** | API Key Tester (Flask dev UI) | Public | `https://s2f1q59mb9tg9r-8888.proxy.runpod.net` |

**Traffic flow:**
```
Browser → :8888 (Tester UI)
              └→ :2222 (Gateway)  [auth, logging, routing]
                    └→ :1111 (vLLM)  [actual AI inference]
```

---

## 3. Component Status

### 3A. Production Gateway (`/workspace/production/`)

| File | Purpose | Status |
|------|---------|--------|
| `main.py` | FastAPI app, lifespan, routers, middleware | ✅ Complete |
| `config.py` | Settings (ports, DB, model paths) | ✅ Complete |
| `auth.py` | API key + JWT auth (bcrypt, jose) | ✅ Complete |
| `database.py` | MySQL via pymysql, all CRUD ops | ✅ Complete |
| `models.py` | Pydantic request/response models | ✅ Complete — `content: Any` + `flat_text()` for multimodal |
| `routers/chat.py` | `/v1/chat` + `/v1/chat/completions` (OpenAI-compat) | ✅ Complete |
| `routers/files.py` | `/v1/files/ask` — upload + smart pipeline | ✅ Complete (pipeline wired) |
| `routers/ocr.py` | PaddleOCR for images | ✅ Complete |
| `routers/admin.py` | Signup, stats, admin panel | ✅ Complete |
| `routers/projects.py` | Project CRUD (custom system prompts) | ✅ Complete |
| `routers/user_auth.py` | JWT login/signup for dashboard | ✅ Complete |
| `routers/api_compat.py` | Extra OpenAI compatibility shims | ✅ Complete |
| `services/llm.py` | `call_llm()` + `stream_llm()`, think-tag stripping | ✅ Complete |
| `services/pipeline.py` | Smart router: Direct / Map-Reduce / RAG | ✅ Complete |
| `services/chunker.py` | `chunk_text()`, `estimate_tokens()` | ✅ Complete |
| `services/embedder.py` | ChromaDB store/search (sentence-transformers) | ✅ Complete |
| `services/file_parser.py` | PDF/Word/Excel/Audio text extraction | ✅ Complete |
| `services/ocr_service.py` | PaddleOCR + parallel PDF OCR | ✅ Complete |
| `services/logger.py` | Structured logging | ✅ Complete |
| `start_all.sh` | Starts supervisord (manages gateway + vLLM) | ✅ Complete |
| `supervisord.conf` | Auto-restart for gateway (port 2222) + vLLM (port 1111) | ✅ Complete |

### 3B. API Key Tester (`/workspace/api-key-tester/`)

| File | Purpose | Status |
|------|---------|--------|
| `app.py` | Flask app — upload, chat, map-reduce | ✅ Complete |
| `templates/index.html` | Gemini-style chat UI | ✅ Complete |
| `requirements.txt` | flask, openai, pdfplumber, openpyxl, requests | ✅ Complete |
| `venv/` | Python virtual environment | ✅ Created |

### 3C. Avaniko Platform (`/workspace/avaniko-platform/`)

| Component | Purpose | Status |
|-----------|---------|--------|
| `backend/` | FastAPI + PostgreSQL (async SQLAlchemy) | ⚠️ Built, NOT deployed |
| `frontend/` | React + Vite + Tailwind dashboard | ⚠️ Built, NOT deployed |
| `nginx/` | Reverse proxy config | ⚠️ Config exists, NOT live |
| `docker-compose.yml` | Full stack Docker deploy | ⚠️ Ready, NOT run |
| `sdk/` | `pip install avaniko-ai` Python SDK | ⚠️ Code written, NOT published |
| `DEPLOY.md` | IIS/Docker deployment guide | ✅ Docs exist |

---

## 4. Database Schema (MySQL — production)

```sql
users         — id, name, email, password, role, is_active
api_keys      — id, user_id, api_key (sk-ava-...), key_name, daily_limit,
                requests_today, total_requests, total_tokens
projects      — project_id, api_key, name, system_prompt, model, temperature
chat_history  — api_key, session_id, role, content, tokens_used
usage_logs    — api_key, endpoint, prompt_tokens, completion_tokens,
                tokens_used, response_time_ms, status
doc_cache     — cache_key, doc_hash, question, answer  (7-day TTL)
```

---

## 5. Model Info

| Property | Value |
|----------|-------|
| Model | Qwen3.6-35B-A3B-GPTQ-Int4 |
| Location | `/workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4/` |
| Served by | vLLM on port 1111 |
| Max context | **16,384 tokens** (hard limit — cannot exceed) |
| Public alias | `avaniko-1` (hides internal model name) |
| Thinking mode | Supported via `chat_template_kwargs: enable_thinking` |
| Think tags | Stripped from output in `chat` mode, shown in `reason` mode |

---

## 6. Smart Pipeline Routing (production + tester)

```
Document uploaded
        │
        ▼
   est_tokens(text)
        │
   ┌────┴──────────────────┐
   │                       │
 < budget             > budget
(fits in 1 call)     (too large)
        │                  │
   DIRECT PATH        MAP-REDUCE
   Send full text     ┌────────────────────────────┐
   to LLM             │  Split → N chunks (350 tok) │
   Stream answer      │  Parallel summarize (6 max) │
                      │  Each summary ≤ 150 tokens  │
                      │  Merge summaries → LLM      │
                      │  Stream final answer        │
                      └────────────────────────────┘

Production also has:
  > 100K tokens → RAG (ChromaDB vector search)
```

---

## 7. Known Issues & Fixes Applied

### 7A. Token Overflow — `400 maximum context length`

**Root cause:** Model max = 16,384 tokens. Prompt + output must be ≤ 16,384.

| Issue | Fix Applied |
|-------|-------------|
| Token estimator `len/4` too optimistic | Changed to `len/3` (conservative) |
| Full doc sent in one call (e.g. 52-chunk PDF = 18K+ tokens) | Map-reduce: split into 350-token chunks, summarize each (150 token output), merge |
| Merge call overflow (52 summaries × 600 tokens = 31K) | Reduced per-summary to 150 tokens max; hard-trim combined to `MAX_INPUT * 3` chars |
| Output budget not reserved | `RESERVE_OUT = 1500` always reserved from input budget |

**Current token budget in tester:**
```
MAX_CONTEXT  = 16,384  (model hard limit)
RESERVE_OUT  = 1,500   (reserved for output)
MAX_INPUT    = 11,000  (hard cap on all input)
CHUNK_TOKENS = 350     (per chunk size)
per summary  = 150     (max tokens each chunk summary)
merge budget = MAX_INPUT - est_tokens(question) - 100
```

### 7B. Streaming Not Working

**Root cause:** `base_url` pointed to external Cloudflare proxy URL which buffers SSE.

| Wrong | Fixed |
|-------|-------|
| `https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1` | `http://localhost:7777/v1` |

Always use `localhost` for internal service calls on RunPod.

### 7C. 422 — `Input should be a valid string`

**Root cause:** OpenAI SDK sends multimodal content as `list` (array of `{type, text}` objects). Production gateway `content: str` rejected it.

**Fix:** Changed `OpenAIMessage.content: str` → `content: Any` + added `flat_text()` method to flatten arrays to plain string.

### 7D. 401 — API Key Missing

**Root cause:** OpenAI SDK sends `Authorization: Bearer <key>`. Gateway expects `x-api-key` header.

**Fix:** `default_headers={"x-api-key": API_KEY}` in OpenAI client constructor.

### 7E. 502 Bad Gateway

**Root cause:** Flask bound to `127.0.0.1:2222` (not `0.0.0.0`). RunPod proxy couldn't reach it.

**Fix:** `app.run(host="0.0.0.0", port=2222)`

### 7F. Single Chunk Stops — Next Chunk Not Processing

**Root cause:** BM25 retrieved top-K chunks but only 1 fit in token budget → other chunks silently dropped.

**Fix:** Full map-reduce in tester — all chunks processed in parallel via `ThreadPoolExecutor(max_workers=6)`, summaries ordered and merged.

### 7G. `NameError: parsed` in production `files.py`

**Root cause:** Line 158 referenced `parsed.get("pages")` but `parsed` was only defined in Word/Excel branches, not PDF branch.

**Fix:** Changed to `pages = None` since page list is not tracked in that code path.

---

## 8. Remaining Issues (Not Yet Fixed)

### 8A. Port Mismatch Between `.env` and `config.py`

```
.env says:        VLLM_PORT=7777  →  http://localhost:7777
config.py says:   VLLM_BASE_URL = "http://localhost:1111"
supervisord.conf: vLLM starts on --port 1111
tester app.py:    base_url = "http://localhost:7777/v1"
```

**Action needed:** Confirm which port vLLM actually runs on, then make all configs consistent.

### 8B. Production Gateway vs Tester Conflict on Port 2222

Both production FastAPI gateway and tester Flask app want port 2222. Only one can run at a time.

**Options:**
- Run tester on port 2223 instead
- Stop production gateway while testing, restart after

### 8C. Tester DOC_STORE is In-Memory Only

If Flask app restarts, all uploaded documents are lost. User must re-upload.

**Fix option:** Persist to disk (pickle/JSON file) or add a Redis/SQLite backend.

### 8D. Production Pipeline — Map-Reduce Merge Can Still Overflow

`pipeline.py` in production builds combined summaries as:
```python
"\n\n---\n\n".join(f"[Section {i+1}]:\n{s}" for i, s in enumerate(summaries))
```
Each summary uses `MAX_OUTPUT = 2048` tokens. For a 30-chunk doc: 30 × 2048 = 61,440 tokens → merge call will overflow.

**Fix needed:** Same fix as tester — reduce per-summary `max_tokens` in `_summarize_chunk` from `MAX_OUTPUT (2048)` to `200`, and trim combined text before merge.

### 8E. avaniko-platform Not Deployed

The public-facing platform (`/workspace/avaniko-platform/`) is fully built but not deployed. It needs:
- A VPS/IIS server
- PostgreSQL database
- `docker compose up -d --build`
- Fill `.env` with real `RUNPOD_GATEWAY_URL` + secrets

### 8F. SDK Not Published to PyPI

`/workspace/avaniko-platform/sdk/` contains `setup.py` + `avaniko_ai/client.py` but `pip install avaniko-ai` is not yet available.

---

## 9. File Reference — What Does What

```
/workspace/
├── .env                        ← RunPod environment config (ports, DB, model path)
├── README.md                   ← Architecture overview
├── current.md                  ← THIS FILE
│
├── production/                 ← ✅ LIVE on RunPod port 2222
│   ├── main.py                 ← FastAPI app entry point
│   ├── config.py               ← Settings (reads .env)
│   ├── auth.py                 ← API key + JWT auth
│   ├── database.py             ← MySQL CRUD (users, keys, logs, cache)
│   ├── models.py               ← Pydantic models (content: Any, flat_text)
│   ├── supervisord.conf        ← Process manager (gateway + vLLM)
│   ├── start_all.sh            ← Start everything with one command
│   ├── routers/
│   │   ├── chat.py             ← /v1/chat + /v1/chat/completions
│   │   ├── files.py            ← /v1/files/ask (smart pipeline)
│   │   ├── ocr.py              ← /v1/ocr (PaddleOCR)
│   │   ├── admin.py            ← /admin/signup, /admin/stats
│   │   ├── projects.py         ← /v1/projects CRUD
│   │   ├── user_auth.py        ← /auth/login, /auth/signup (JWT)
│   │   └── api_compat.py       ← Extra OpenAI-compat shims
│   └── services/
│       ├── llm.py              ← call_llm(), stream_llm(), think-tag strip
│       ├── pipeline.py         ← Smart router: direct / map-reduce / RAG
│       ├── chunker.py          ← chunk_text(), estimate_tokens()
│       ├── embedder.py         ← ChromaDB store/search
│       ├── file_parser.py      ← PDF/Word/Excel/Audio extraction
│       ├── ocr_service.py      ← PaddleOCR, parallel PDF OCR
│       └── logger.py           ← Structured logging
│
├── api-key-tester/             ← ✅ Dev test UI on port 2222
│   ├── app.py                  ← Flask: upload, BM25, map-reduce chat
│   ├── templates/index.html    ← Gemini-style dark chat UI
│   └── requirements.txt        ← flask, openai, pdfplumber, openpyxl
│
├── avaniko-platform/           ← ⚠️ NOT YET DEPLOYED
│   ├── backend/                ← FastAPI + PostgreSQL (async)
│   ├── frontend/               ← React dashboard (Vite + Tailwind)
│   ├── nginx/nginx.conf        ← Reverse proxy config
│   ├── docker-compose.yml      ← Full stack deploy
│   ├── sdk/                    ← pip install avaniko-ai (not published)
│   └── DEPLOY.md               ← Deployment instructions
│
└── models/                     ← Qwen3.6-35B model weights
    └── Qwen3.6-35B-A3B-GPTQ-Int4/
```

---

## 10. API Endpoints (Production Gateway)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/v1/chat` | x-api-key | Native chat (stream or non-stream) |
| POST | `/v1/chat/completions` | x-api-key | OpenAI-compatible chat |
| GET | `/v1/models` | none | List available models |
| POST | `/v1/files/ask` | x-api-key | Upload file + ask question (streaming) |
| POST | `/v1/files/store` | x-api-key | Store doc in ChromaDB for RAG |
| POST | `/v1/files/query` | x-api-key | Query stored RAG documents |
| POST | `/v1/ocr/upload` | x-api-key | OCR image/PDF → JSON |
| POST | `/v1/projects` | x-api-key | Create AI project config |
| GET | `/v1/projects` | x-api-key | List projects |
| PUT | `/v1/projects/{id}` | x-api-key | Update project |
| DELETE | `/v1/projects/{id}` | x-api-key | Delete project |
| POST | `/auth/signup` | none | Register user (JWT) |
| POST | `/auth/login` | none | Login → get JWT |
| POST | `/admin/signup` | none | Create API key (legacy) |
| GET | `/admin/stats` | admin | Platform stats |
| GET | `/health` | none | Gateway + vLLM + DB status |
| GET | `/docs` | none | Swagger UI |

---

## 11. How to Start (RunPod)

### Start everything (production):
```bash
cd /workspace
bash production/start_all.sh
```

### Start tester only (for development):
```bash
cd /workspace/api-key-tester
source venv/bin/activate
python app.py
# Listens on 0.0.0.0:2222
```

### Check what's running on port 2222:
```bash
ss -tlnp | grep 2222
```

### Kill whatever is on port 2222:
```bash
pkill -f "app.py"       # kills tester
pkill -f "uvicorn"      # kills production gateway
```

---

## 12. Priority Fix List

| Priority | Issue | File | Fix |
|----------|-------|------|-----|
| 🔴 HIGH | Port mismatch: vLLM on 1111 vs tester uses 7777 | `app.py` line 21, `.env` | Confirm port, align all configs |
| 🔴 HIGH | Production map-reduce merge can overflow (2048 tokens/summary) | `services/pipeline.py` `_summarize_chunk()` | Reduce to 200 max_tokens |
| 🟡 MED | Port 2222 conflict between tester and production | `supervisord.conf`, `app.py` | Move tester to port 2223 |
| 🟡 MED | Tester DOC_STORE lost on restart | `api-key-tester/app.py` | Add JSON/SQLite persistence |
| 🟢 LOW | avaniko-platform not deployed | `avaniko-platform/` | Docker deploy to VPS |
| 🟢 LOW | SDK not on PyPI | `avaniko-platform/sdk/` | `python setup.py upload` |

---

## 13. Quick Test Commands

```bash
# Health check
curl http://localhost:2222/health

# Chat test
curl -X POST http://localhost:2222/v1/chat/completions \
  -H "x-api-key: sk-ava-g_6pbsaW3MvQiB8KEhvb6L1KEqWhQv_GdtxSAVkRCIY" \
  -H "Content-Type: application/json" \
  -d '{"model":"avaniko-1","messages":[{"role":"user","content":"Hello"}],"stream":false}'

# Check logs
tail -f /workspace/production/logs/gateway.log
tail -f /workspace/production/logs/vllm.log
```
