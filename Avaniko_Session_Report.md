# Avaniko AI Platform — Full Session Report

**Date:** 2026-06-10  
**Engineer:** Claude (AI Assistant)  
**User:** surya.inbasagaran@avaniko.com  

---

## 1. Initial State

When the session started, the following services were running:

| Service | Port | Status |
|---|---|---|
| vLLM (Qwen3.6-35B-A3B-GPTQ-Int4) | 7777 | Running |
| Production FastAPI Gateway | 7778 | Running |
| Avaniko React Dashboard | 1111 | Running (static serve) |
| API Key Tester | 2222 | Running |

**Model:** `Qwen3.6-35B-A3B-GPTQ-Int4` — text-only MoE model, **no vision support**

---

## 2. Bugs Found and Fixed

### Bug 1 — `system_override` Never Passed to Pipeline
**File:** `/workspace/production/routers/chat.py`  
**Problem:** All 4 `process_document()` call sites were missing `system_override=system_prompt`. The pipeline always used its own generic prompts, ignoring any custom system prompt the user set (e.g. "extract as JSON").  
**Fix:** Added `system_override=system_prompt` to all 4 call sites and passed `system_prompt` into `_extract_question()`.

---

### Bug 2 — Same Invoice Output for Every Different PDF
**File:** `/workspace/production/services/pipeline.py`  
**Problem:** `doc_hash(text[:4096])` — only the first 4096 characters were hashed. Two invoices from the same vendor template had identical openings, so they got the same cache key. The first extraction result was returned for every subsequent invoice.  
**Also:** `cache_set()` was caching errors and empty results, so a failed extraction would poison the cache permanently.  
**Fix:**
```python
# Before
def doc_hash(text: str) -> str:
    return hashlib.md5(text[:4096].encode()).hexdigest()

# After — hash full text
def doc_hash(text: str) -> str:
    return hashlib.md5(text.encode()).hexdigest()
```
Added guards to never cache errors or results shorter than 20 chars.

---

### Bug 3 — Image Files Always Returning Old PDF Data (Production Gateway)
**File:** `/workspace/production/routers/files.py`  
**Problem:** Images were being sent to vLLM's vision API. Since the model (`Qwen3.6-35B`) is **text-only** with no vision support, vLLM silently returned "I am Avaniko AI..." identity text instead of OCR. This garbage text was then stored in the doc cache and served to every subsequent request.  
**Fix:** Replaced vLLM vision call with PaddleOCR via `run_in_executor`. Added fallback message if OCR returns empty.

---

### Bug 4 — Multi-file Upload Handler Broken (Static HTML)
**File:** `/workspace/production/routers/files.py`  
**Problem:** The multi-file handler called `r.json()` on a streaming SSE endpoint, which always fails.  
**Fix:** Added `stream=False` mode to `/v1/files/ask` — returns plain JSON when `stream=False`, SSE when `stream=True`.

---

### Bug 5 — API Key Tester: Same Output for Every File
**File:** `/workspace/api-key-tester/app.py`  
**Problem 1:** `doc_id = hashlib.md5((fname + fdata[:64]).encode())` — only 64 bytes of file content used in hash. Two different files with the same name got the same `doc_id`.  
**Problem 2:** OCR used vLLM vision API (same as Bug 3) — returned identity text, stored in MySQL, served forever.  
**Fix:** Full file content hash `hashlib.md5(raw).hexdigest()[:16]`. Replaced vLLM vision with PaddleOCR.

---

### Bug 6 — Session History Overflow → Empty Document Context
**File:** `/workspace/api-key-tester/app.py`  
**Problem:** Session `741d8622` accumulated 26 messages = 16,489 history tokens.  
`available = 10000 - 16489 - 5 - 300 = -6794`  
`part[:−6794*3]` = empty string → model received **zero document context** → repeated last cached Northwind JSON from history.  
**Fix:**
```python
MAX_HIST_TOKENS = int(MAX_INPUT * 0.30)  # cap history at 30% = 3000 tokens
while history_tokens > MAX_HIST_TOKENS and len(history) >= 2:
    history = history[2:]  # drop oldest user+assistant pair

merge_budget   = max(2000, MAX_INPUT - query_tokens - history_tokens - 300)
per_part_budget = max(500, merge_budget // n_parts)
```
Also truncated the MySQL `tester_history` table to clear the bloated session.

---

### Bug 7 — Dashboard File Uploads Blank (Port 1111)
**File:** `/workspace/avaniko-platform/frontend/src/lib/api.js`  
**Problem:** `streamFileChat()` never sent `stream=true` in the form data. The backend defaulted to `stream=False` (JSON response), but the frontend expected SSE — so nothing was yielded.  
**Fix:**
```javascript
formData.append("stream", "true");  // added
```

---

### Bug 8 — PaddleOCR Returning 0 Chars on All Images
**Root cause investigation:**
1. First attempt: resize to 2400px — still 0 chars
2. Discovered: `No module named 'paddleocr'` — the api-key-tester venv didn't have PaddleOCR installed at all
3. Added `/workspace/venv/lib/python3.12/site-packages` to sys.path — got next error
4. `np.sctypes was removed in the NumPy 2.0 release` — PaddleOCR 2.9.1 uses removed NumPy API
5. Same error in both venvs (both have NumPy 2.x)

**Resolution — Install PaddleOCR 3.1.1:**
```bash
pip install numpy==1.26.4       # restores np.sctypes
pip install paddlepaddle==3.1.1
pip install paddleocr==3.1.1
```

**Additional fix — PaddlePredictorOption API mismatch:**  
`paddleocr/_common_args.py` called `PaddlePredictorOption(model_name, ...)` as a positional arg, but `paddlex 3.6.1`'s `__init__` only accepts `**kwargs`. Patched the call:
```python
# Before (broken)
pp_option = PaddlePredictorOption(model_name, device_type=device_type, device_id=device_id)

# After (fixed)
pp_option = PaddlePredictorOption(device_type=device_type, device_id=device_id)
if model_name:
    pp_option.setdefault_by_model_name(model_name)
```

**Result format change (3.1.1):** Old format was `result[0] → line[1][0]`. New format is `OCRResult` dict with `rec_texts` key:
```python
for page in result:
    texts = page.get("rec_texts", [])
    lines.extend(texts)
```

**OCR warmup:** PaddleOCR 3.1.1 loads 5 models on first use (~2 min). Added background warmup thread at startup so the first upload request isn't blocked.

---

### Bug 9 — Port 1111 Running Static Server (No API Proxy)
**Problem:** `node serve -s dist -p 1111` is a **static file server only** — it cannot proxy requests. Every API call (`/v1/chat/completions`, `/auth/login`) returned `index.html`, completely breaking the chatbot.  
**Fix 1:** Switched to Vite dev server (`npm run dev`) — but Vite's WebSocket HMR fails behind RunPod's proxy, causing 502 errors on JS module requests.  
**Fix 2:** Built frontend (`npm run build`) and added an nginx server block that:
- Serves `dist/` as static files  
- Proxies `/v1/`, `/auth/`, `/health/`, `/admin/` to port 7778

---

## 3. Final Cleanup (User Request)

The user requested to remove all complexity and keep only vLLM.

### Deleted
- `/workspace/avaniko-platform/` — React dashboard + Vite frontend
- `/workspace/production/` — FastAPI gateway, routers, services
- `/workspace/api-key-tester/` — Flask playground app
- `/workspace/avaniko-gateway/` — Additional gateway code
- nginx port 1111 server block — removed from `/etc/nginx/nginx.conf`

### Stopped
- Production FastAPI gateway (port 7778)
- API Key Tester Flask app (port 2222)
- Vite dev server (port 1111)
- `node serve` static server (port 1111)

---

## 4. Current State

### What Is Running

| Service | Port | PID | Status |
|---|---|---|---|
| **vLLM** | 7777 | 16480 | ✅ Running |

### What Is Gone
- All dashboards
- All gateways
- All authentication
- All OCR services
- All API key management

### Workspace Contents
```
/workspace/
├── models/          (23 GB) — Qwen3.6-35B-A3B-GPTQ-Int4 model weights
├── venv/            (28 GB) — Python venv with vLLM + dependencies
├── db_setup.sql     — MySQL schema (unused)
├── setup.sh         — Original setup script
├── test.jpg         — Test image
├── test.pdf         — Test PDF
└── README.md
```

### vLLM Direct API
```bash
# Health check
curl http://localhost:7777/health

# List models
curl http://localhost:7777/v1/models

# Chat (non-streaming)
curl http://localhost:7777/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b",
    "messages": [{"role": "user", "content": "hello"}],
    "stream": false
  }'

# Chat (streaming)
curl http://localhost:7777/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b",
    "messages": [{"role": "user", "content": "hello"}],
    "stream": true
  }'
```

---

## 5. Key Learnings

| # | Learning |
|---|---|
| 1 | `Qwen3.6-35B` is **text-only** — no vision/image support in vLLM |
| 2 | PaddleOCR 2.9.1 is **broken on NumPy 2.x** — use 3.1.1 + numpy 1.26.4 |
| 3 | `paddleocr 3.1.1` + `paddlex 3.6.1` have an API mismatch that needs a 1-line patch |
| 4 | PaddleOCR 3.1.1 result format changed: use `result[0]['rec_texts']` not `result[0][i][1][0]` |
| 5 | Always hash **full file content** for doc cache keys — prefix hashing causes collisions |
| 6 | Session history must be capped — uncapped history causes negative token budget → empty context → model repeats old answers |
| 7 | RunPod proxy does **not** support Vite dev server WebSocket HMR — always serve built static files via nginx |
| 8 | `node serve -s` is static-only — use nginx for SPA + API proxy |
| 9 | Pre-warm heavy ML models (PaddleOCR, Whisper) in background threads at startup |

---

*Report generated: 2026-06-10*
