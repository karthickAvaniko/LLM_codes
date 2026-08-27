# Avaniko AI Gateway — Full Technical Documentation & Spec

**Scope:** Complete reference for the RunPod-hosted gateway at `/workspace/gateway/main.py` — the model it serves, every service in the pod, the full API surface, the internal engines (task routing, context safety, OCR/extraction, RAG), auth/security model, database schema, logging, deployment, and known risks.

**Status:** Living document, generated 2026-08-21 by reading the running code and live process state directly (not from older docs, which contain some now-stale facts called out below).

---

## 1. What this system is

Avaniko AI Gateway is a self-hosted, OpenAI-API-compatible inference gateway running on a single RunPod GPU pod. One FastAPI process fronts a locally-served large language model (white-labeled as `avaniko-ai`), an OCR microservice, an embedding microservice, and a MariaDB instance — all colocated on one pod, with only the gateway's port exposed publicly.

It serves four kinds of traffic: OpenAI-compatible chat completions, document upload + single-document Q&A, retrieval-augmented Q&A across a whole document library, and structured batch invoice/document extraction to JSON.

---

## 2. The model — how it works

**Model:** `Qwen3.6-35B-A3B-GPTQ-Int4`, on disk at `/workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4`.

| Property | Value |
|---|---|
| Architecture | `Qwen3_5MoeForConditionalGeneration` — Mixture-of-Experts |
| Experts | 256 total, **8 active per token** |
| Hidden size | 2048, MoE intermediate size 512 |
| Layers | 40 hidden layers — mostly `linear_attention`, with `full_attention` every 4th layer (hybrid linear/full attention, not a vanilla transformer) |
| Vocab | 248,320 tokens |
| Native context | 262,144 tokens (trained) — **served at 32,768** (operational cap, see §6.2) |
| Vision | Native multimodal encoder built in (depth 27, hidden 1152, patch size 16) — the model can see images directly, not just OCR text |
| Quantization | GPTQ 4-bit, group size 128, symmetric (`gptqmodel:6.0.3`); attention, MTP, shared-expert, visual, and LM-head weights are kept at higher precision (dynamic exclusion) — only the MoE feed-forward weights are 4-bit |
| Multi-token prediction | A dedicated 1-layer MTP head ships alongside the main weights for faster decoding |

**Served via vLLM**, exact live launch command (confirmed from the running process):

```
python -m vllm.entrypoints.openai.api_server \
  --model /workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4 \
  --served-model-name qwen3.6-35b \
  --host 127.0.0.1 --port 7777 \
  --dtype float16 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.85 \
  --max-num-seqs 16 \
  --trust-remote-code \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder
```

- **`--max-num-seqs 16`** is the real, current concurrency cap — vLLM will run at most 16 generations in parallel; request #17 queues. (Older docs in this repo still say 8 — that was true before this session's tuning change; see §12.)
- Runs on **1× NVIDIA RTX A6000, 48GB VRAM** (driver 580.173.02, CUDA 13.0), currently ~41.6GB in use.
- vLLM binds to `127.0.0.1:7777` only — it is never exposed publicly; all traffic reaches it through the gateway.

**White-labeling.** Internally the model is always called `qwen3.6-35b`; the gateway rewrites this to the public name `avaniko-ai` everywhere — including inside raw streamed SSE bytes, byte-for-byte, so a streaming client never sees the real model name. A system prompt (`IDENTITY_PROMPT`) additionally instructs the model itself never to reveal it is built on Qwen/Alibaba technology if asked directly.

---

## 3. Service topology

Five processes share the one pod. Only the gateway is reachable from outside.

| Service | Port | Bind | Process | Purpose |
|---|---|---|---|---|
| **Gateway** | 7778 | `0.0.0.0` (public) | `uvicorn main:app --workers 1 --loop asyncio --timeout-keep-alive 300` | All public routes — auth, chat, files, RAG, extract, admin |
| **vLLM** | 7777 | `127.0.0.1` | vLLM OpenAI-compatible server (command above) | LLM + vision inference |
| **Embeddings** | 7779 | `127.0.0.1` | `uvicorn embed_server:app` | `sentence-transformers/all-MiniLM-L6-v2`, CPU, 384-dim vectors, powers RAG retrieval |
| **OCR** | 7780 | `127.0.0.1` | `uvicorn ocr_server:app` (own venv, `OMP_NUM_THREADS=1`) | PaddleOCR, isolated process — an OCR crash never takes the gateway down |
| **MariaDB** | 3306 (socket) | `127.0.0.1` | `mariadbd --datadir=/workspace/mysql`, wrapped in a `while true` respawn loop | Stores API keys, user accounts, sessions |

**Public URL:** RunPod's reverse proxy, `https://<POD_ID>-7778.proxy.runpod.net`. **This URL changes on every pod restart** because it's keyed to the pod ID. Current live URL (verified 2026-08-21): `https://s2f1q59mb9tg9r-7778.proxy.runpod.net`. Several older docs in this repo (`API_GUIDE.md`, `invoice_to_json.py`) still hardcode a previous pod's URL (`g9s7n0soow3h5q-...`), which now 404s — treat any hardcoded proxy URL as provisional and re-verify with `/health` before relying on it.

### Startup sequence (`start_all.sh`)

1. **vLLM** starts first (slowest — model load onto GPU)
2. **MariaDB** starts, wrapped in its own respawn loop (`--datadir=/workspace/mysql`)
3. **OCR server**, also in a respawn loop, own virtualenv
4. **Embedding server**
5. **Gateway**, launched *through* `gateway_watchdog.sh` rather than directly
6. A daily backup loop (`backup.sh`, 14-day retention, writes to `/workspace/backups`)

### The watchdog (`gateway_watchdog.sh`)

Polls `GET /health` every 15 seconds. Two consecutive failures (~30s) → `kill -9` on the gateway process, restart after 3s. Deliberately logs to **`/tmp`**, not `/workspace` — `/workspace` is a network-mounted volume (RunPod's MooseFS-backed storage) known to stall under I/O pressure, and a blocked log write there could freeze the watchdog itself, defeating its purpose.

---

## 4. Request lifecycle (two worked examples)

**A chat request** (`POST /v1/chat/completions`):
1. Middleware resolves the `Authorization: Bearer` token to a key (or the master admin key) → attaches `key_hash` to the request.
2. Any inline image parts are OCR'd/resolved.
3. If `tools`/`tool_choice` are present, the request goes straight through in **agent passthrough mode** (task detection and web search are skipped so nothing interferes with tool-call pairing).
4. Otherwise the `task` is routed (explicit or auto-detected) to a preset (temperature/max_tokens/thinking-mode).
5. An identity + date system message is merged in; web search runs if triggered; message history is trimmed to fit the context budget.
6. The (possibly-streaming) call goes to vLLM at `127.0.0.1:7777`, with automatic prompt-shrink-and-retry if vLLM reports a context overflow — the client never sees a raw context-length 400.
7. The response (and, for streams, every chunk) has `qwen3.6-35b` rewritten to `avaniko-ai`.
8. The full exchange is logged to `requests.jsonl` off the event loop (fire-and-forget thread executor).

**An extraction request** (`POST /v1/extract`):
1. Each uploaded file is text-extracted (native PDF text, OCR-filled per page where native text is short) and page-rendered as images, in parallel (semaphore of 5 concurrent files).
2. Small/simple documents go through the **vision-hybrid** path — real page images plus OCR text sent together, since the model can natively see logos, stamps, and layout that OCR text alone can't represent. Larger documents fall back to text-only map-reduce.
3. If `consistency > 1`, several independent passes are merged by per-field majority vote (or the cleanest single sample, if the samples disagree on JSON shape).
4. The result is run through ~10 deterministic validation checks (amount math, duplicate rows, missing vendor/date, total reconciliation, etc.).
5. Any hard validation failure triggers **one automatic self-correction pass**, re-validated afterward.
6. The final JSON (plus a validation report) is returned per file; one file's failure never fails the whole batch.

---

## 5. Full API reference

### 5.1 Auth model (three tiers)

The gateway's global middleware (`require_api_key`) routes every request into one of three buckets:

| Bucket | Applies to | Credential |
|---|---|---|
| **Public** | `/`, `/health`, `/keys`, `/getkey`, `/signup/key`, `/console`, `/admin`, `/auth/login`, `/auth/admin-login`, `/auth/register`, `/auth/signin` | none |
| **Session** | `/me/*`, `/admin-api/*`, `/auth/logout` | `st-` session token (cookie), issued by `/auth/signin`; `/admin-api/*` additionally requires the session belongs to the admin account |
| **API key** | everything else, including all `/v1/*` | `Authorization: Bearer ak-...` |

The **master admin key** (stored at `/workspace/gateway/.api_key`, checked with `secrets.compare_digest`) satisfies the API-key bucket everywhere — it is valid on `/v1/*` exactly like a customer key, in addition to unlocking `/admin/*`, and it bypasses per-key rate limiting entirely.

### 5.2 Route inventory

| Route | Method | Auth | Purpose |
|---|---|---|---|
| `/` | GET | public | Chat UI |
| `/keys` | GET | public (HTML shell) | Admin key console page |
| `/console` / `/admin` | GET | public (HTML shell) | Developer / admin console page |
| `/auth/signin` | POST | public | Unified login (detects admin vs. regular user) |
| `/auth/admin-login` | POST | public | Admin-only login |
| `/auth/register` | POST | public | **Disabled** — always returns 403 |
| `/auth/login` | POST | public | Regular user login |
| `/auth/logout` | POST | session | Destroy session |
| `/me/keys` | GET | session | List your own keys |
| `/me/usage` | GET | session | Your own usage rollup |
| `/admin-api/users` | GET / POST | admin session | List / create user accounts |
| `/admin-api/users/{email}` | DELETE | admin session | Delete a user and revoke their keys |
| `/admin-api/keys` | GET / POST | admin session | List / create keys tied to a user account |
| `/admin-api/keys/{id}` | DELETE | admin session | Revoke (soft delete) |
| `/admin-api/keys/{id}/thinking` | POST | admin session | Toggle a key's default "thinking mode" |
| `/admin-api/keys/{id}/ocr` | POST | admin session | Toggle a key's access to document/OCR endpoints |
| `/admin-api/keys/{id}/delete` | POST | admin session | Hard delete |
| `/getkey` | GET | public | Self-service signup page |
| `/signup/key` | POST | public | Self-service trial key (**currently closed**) |
| `/health` | GET | public | `{"gateway":"ok","vllm":"ok"\|"down","model":"avaniko-ai"}` |
| `/admin/keys` | POST / GET | master key | Create / list keys — flat, no user account required |
| `/admin/keys/{id}` | DELETE | master key | Revoke a key |
| `/admin/keys/{id}/enable` | POST | master key | Re-enable a revoked key |
| `/v1/models` | GET | API key | `{"data":[{"id":"avaniko-ai", ...}]}` |
| `/v1/usage` | GET | API key | Caller's own usage stats |
| `/v1/files` | POST / GET | API key | Upload (multipart `file=` or `url=`) / list your files |
| `/v1/files/{id}` | GET / DELETE | API key | File status / delete |
| `/v1/files/{id}/ask` | POST | API key | Ask a question about ONE document (full extraction, not RAG) |
| `/v1/ask` | POST | API key | RAG — ask across all (or selected) stored documents |
| `/v1/extract` | POST | API key | Batch structured extraction, up to 20 files |
| `/v1/chat/completions` | POST | API key | OpenAI-compatible chat |
| `/chat` | POST | API key | Legacy SSE endpoint used internally by the HTML chat UI |
| `/files/ask` | POST | API key | Legacy multi-file streaming Q&A with progress heartbeats (predates `/v1/files` + `/v1/extract`) |

**`/admin/*` vs. `/admin-api/*` are not duplicates.** `/admin/keys*` is the scriptable, master-key-authenticated API (the one documented in `API_GUIDE.md` for curl/terminal use) and creates keys with no user account attached. `/admin-api/*` is the logged-in web console's backend — it operates on user accounts too, requires every key to belong to an existing user, and exposes extra per-key toggles the flat API doesn't have.

**`/chat` and `/files/ask` are not dead code.** `/chat` is what the bundled HTML chat UI actually calls (always thinking-aware, always auto web-search); `/v1/chat/completions` is the public OpenAI-compatible surface (task presets, tool-calling passthrough). `/files/ask` is an older multi-file streaming Q&A path still used by the UI's drag-and-drop chat attachments, with its own (duplicated) validation/self-correction logic — a real second code path, not just legacy cruft, but a maintenance liability (see §11).

### 5.3 Key endpoint details

**`POST /v1/chat/completions`** — OpenAI-compatible.
```json
{
  "model": "avaniko-ai",
  "messages": [{"role": "user", "content": "Hello"}],
  "task": "auto",
  "web_search": "auto",
  "stream": false,
  "max_tokens": 4096
}
```
- `task`: `auto` | `chat` | `reasoning` | `coding` | `extraction` | `classification` — see §6.1 for what each preset does.
- `web_search`: `true` forces a live DuckDuckGo search injected as context with `[1][2]` citations; `false` disables it; omitted/`"auto"` lets a tiny classifier call decide.
- `max_tokens` is capped at 8192 server-side regardless of what's requested.
- If `tools`/`tool_choice` are present, task/web-search logic is skipped entirely (agent passthrough mode).

**`POST /v1/extract`** — multipart/form-data.

| Field | Type | Default | Notes |
|---|---|---|---|
| `files` | file (repeatable) | required | up to 20 files, 50MB each |
| `question` | text | generic extraction prompt | what to extract |
| `hints` | text | "" | per-document OCR-quirk notes |
| `output_schema` | text | "" | JSON Schema string → constrains output via vLLM guided decoding |
| `consistency` | text (int) | 1 | 1–5, self-consistency voting |
| `canonicalize` | text (bool) | false | normalize field names semantically |

Response:
```json
{
  "question": "...",
  "files": 1,
  "ms": 4230,
  "results": [
    {
      "filename": "invoice.pdf",
      "pages": 1,
      "strategy": "vision_hybrid",
      "answer": "{\"invoice_no\": \"...\", \"total_amount\": \"...\"}",
      "validation": {"ok": true, "issues": [], "corrected": false}
    }
  ]
}
```

**`POST /v1/ask`** — RAG across stored files.
```json
{ "question": "Which vendor invoice has the highest amount?", "file_ids": null, "top_k": 5, "stream": false }
```
Returns `{"answer": "...", "sources": [{"file_id","filename","page","score"}, ...]}`.

**`POST /v1/files`** — multipart `file=` upload, or `url=` (auto-converts Google Sheets/Drive share links). Allowed types: pdf, png, jpg, jpeg, webp, bmp, tiff, txt, csv, md, json, html, docx, xlsx, xls. Processing happens in the background; poll `GET /v1/files/{id}` until `status` leaves `"processing"`.

---

## 6. Core engines

### 6.1 Task routing & presets

| Task | Temp | Max tokens | Thinking | Notes |
|---|---|---|---|---|
| `extraction` | 0.0 | 2048 | off | `seed=42` for determinism |
| `coding` | 0.2 | 8192 | off | |
| `reasoning` | 0.6 | 8192 | **on** | only preset with thinking enabled |
| `chat` | 0.7 | 4096 | off | default conversational tone |
| `classification` | 0.0 | 256 | off | short, deterministic |

`auto` (the default) calls a tiny 4-token, temperature-0 classifier LLM call to pick a task — except messages over 4000 characters, which skip straight to `extraction`, and any request carrying a resolved image, which is always forced to `extraction`. A per-key admin override for "thinking mode" beats the preset unless the client explicitly sets chat-template kwargs itself.

### 6.2 Context & token safety — six layers

The model's operational context window is 32,768 tokens. Six independent mechanisms keep any single request from exceeding it and failing:

1. **Budgeting** — `_ctx_char_budget()` computes a conservative char budget (~1.7 chars/token) for whatever `max_tokens` was requested.
2. **Auto-shrink-and-retry** — if vLLM still reports a context overflow, the gateway shrinks the prompt by 40% and retries, up to 4 times, before giving up. A raw 400 never reaches the client this way.
3. **History trimming** — `_fit_messages()` keeps the system prompt and newest messages, dropping the oldest, before the request is even sent.
4. **Inline-image handling** — images are OCR'd/resolved up front rather than left as raw high-token payloads.
5. **Document map-reduce** — documents over 40,000 characters are chunked (≤35,000 chars/chunk), mapped in parallel, then reduced hierarchically in groups of 5 until small enough for one final call.
6. **RAG** — for cross-document Q&A, only the top-5 most relevant chunks (of up to 20 candidates) are ever sent to the model, so prompt size is constant whether 1 document or 500 are stored.

**Known gap (live bug):** the truncation-retry escalation (`_llm_retry_truncation`) steps through fixed tiers `{8192, 24000, 30000}` regardless of how large the prompt already is. If `prompt_tokens + tier > 32768`, vLLM rejects the request outright instead of the retry recovering — confirmed live in `vllm.log` on 2026-08-20. See §11.

### 6.3 OCR & extraction pipeline

- **Text extraction** (`extract_pages`): native PDF text via PyMuPDF first; any page with under ~300 characters of native text is OCR'd via the isolated OCR microservice, and the longer of {native, OCR} text wins **per page**, not per document.
- **Vision-hybrid** (`extract_page_images` + vision-capable prompt): used when the document has renderable pages, page count is small, and total text is ≤40,000 characters. Sends the model both the OCR text and the actual rendered page images (2× zoom, 3× for dense tables), because the model's native vision encoder can catch logos, stamps, and layout that text alone loses — and can cross-check a misread digit against what it visually sees. Falls back to text-only map-reduce on context overflow.
- **Self-consistency**: with `consistency > 1`, N independent passes run in parallel; if the resulting JSON samples share the same top-level shape they're deep-merged by per-field majority vote; if they disagree on shape, the single sample with the fewest hard validation issues is kept (never a blind union of incompatible structures, which could let two contradictory values for the same fact both survive under different field names).
- **Deterministic validation** (~10 checks, independent of the model): empty line items, quantity×price vs. stated amount mismatches, type mismatches in numeric columns, duplicate rows, subtotal/tax/total reconciliation, a line item accidentally being a subtotal row, missing vendor/buyer/invoice-date/due-date/invoice-number, missing currency.
- **Self-correction**: any hard validation failure triggers exactly one automatic correction pass (given the exact list of issues, plus the original images if vision was used), then a final re-validation so the caller knows whether the fix actually landed.
- **Canonicalization** (optional): a semantic field-name normalization pass after correction.

Measured accuracy over the last 100 real `/v1/extract` calls (per `GPU_ACCURACY_OPTIMIZATION_REPORT.md`): 0% hard errors, 81% pass all validation checks on the first try, 19% flagged (mostly total-mismatch and missing-invoice-number cases, corrected automatically where possible).

### 6.4 RAG pipeline (`/v1/ask`)

- Documents are chunked page-by-page, ≤1800 characters per chunk with 1500-character stride overlap.
- Each chunk is embedded locally (all-MiniLM-L6-v2, 384-dim, cosine similarity via normalized dot product) and cached to disk (`{file_id}.vec.npy` + `{file_id}.rag.json`), plus an in-memory cache.
- At query time: embed the question, retrieve the top 20 candidate chunks across the (filtered) file set, then keep the top 5 (client can request up to 10 via `top_k`) — this is what keeps prompt size constant regardless of how many documents are stored.
- Supports SSE streaming and scoping the search to specific `file_ids`.

### 6.5 Files API lifecycle

Uploaded files are stored flat under `/workspace/gateway/files/`, with metadata and extracted pages as sidecar JSON files. Processing runs as a background asyncio task; status moves `processing → ready` or `processing → error`. If the gateway restarts mid-processing, a startup hook recovers any file stuck in `processing` to an `error` state with a re-upload prompt, rather than leaving it silently stuck forever. Each key is capped at 200 stored files (the master key is exempt); files are strictly scoped to the key that uploaded them.

---

## 7. Auth & security model

- **Two independent key systems**: MySQL-backed customer keys (created via `/admin/keys` or `/admin-api/keys`) and the single, file-based master admin key (never stored in the database, never expires, bypasses rate limiting, checked with a constant-time comparison).
- **Customer keys never expire by design** — an explicit revoke (`active=0`) is the only way to disable one, except self-service trial keys, which are meant to expire after 30 days.
- **Rate limiting is in-process**: a sliding 60-second window per key for requests/minute, plus a UTC-day counter for the daily cap. This is held in plain Python memory, not a shared store — see §11 for why that blocks scaling to more than one worker.
- **Brute-force protection**: more than 20 failed auth attempts per IP per minute triggers a 429 with a `Retry-After: 60` header.
- **OCR/document endpoints** (`/v1/extract`, `/v1/ask`, `/v1/files*/ask`) are individually gate-able per key via an `ocr_enabled` toggle, defaulting to on.
- **Sessions** (for the web console) use `st-` prefixed tokens, SHA-256 hashed, 7-day expiry, cached in memory with a MySQL-backed fallback so a restart doesn't log everyone out.
- **User accounts**: self-registration is disabled (`/auth/register` always returns 403) — accounts are admin-created only, email must match the company domain, and passwords are hashed with PBKDF2-HMAC-SHA256 at 200,000 iterations with a per-user salt. Each user can hold up to 3 keys.
- **Usage counters** are flushed from memory to MySQL every 15 seconds, off the event loop (via a thread executor), specifically because MariaDB's datadir lives on the same network volume implicated in the gateway's stability issues (§11) — a stuck write there is confined to its own thread instead of freezing every request.

---

## 8. Database schema (MariaDB, `avaniko` DB)

Three tables:

- **`api_keys`** — `key_hash` (PK), `raw_key`, `id`, `name`, `email`, `created`, `active`, `expires`, `rpm_limit`, `daily_limit`, `requests`, `tokens_in`, `tokens_out`, `last_used`, `self_service`, `thinking`, `ocr_enabled`
- **`sessions`** — `token_hash` (PK), `email`, `created`, `expires` (epoch)
- **`users`** — `id` (PK, autoincrement), `email` (unique), `name`, `pw_hash`, `created`, `active`

**Note:** `/workspace/db_setup.sql` describes a different, unused legacy schema (`avaniko_llm` database with `chat_history`/`usage_logs` tables) that the running code never queries — it's stale and should not be treated as current. The real, live schema is only reflected in `/workspace/gateway/avaniko_db.sql` (a mysqldump used for backup/restore).

---

## 9. Logging & observability

| File | Location | Contents |
|---|---|---|
| `access.jsonl` | `/workspace/logs/` | Every HTTP request: IP, method, path, status, duration, auth |
| `requests.jsonl` | `/workspace/logs/` | Full question/answer/OCR bodies (values truncated), rotates at 200MB |
| `extraction_telemetry.jsonl` | `/workspace/logs/` | Per-LLM-call token/truncation stats and per-document summaries |
| `gateway_app.log` | `/workspace/logs/` | Python `logging` root-logger output — **the file at the center of the #1 stability risk in §11** |
| `vllm.log`, `ocr.log`, `mysql.log` | `/workspace/logs/` | Respective service stdout/stderr |
| `gateway.log`, `gateway_watchdog.log` | `/tmp/` | Gateway stdout and watchdog status — deliberately kept off the network volume |

---

## 10. Deployment & operations

- **Restart everything:** `bash /workspace/start_all.sh`
- **Check health:** `curl http://localhost:7778/health`
- **Master admin key:** `cat /workspace/gateway/.api_key`
- **Backups:** a daily loop retains 14 days of backups in `/workspace/backups`
- **Housekeeping:** a 17.5GB orphaned `avaniko-project.zip` sits in `/workspace` — not a capacity risk (the volume is at 83% with 135TB free) but worth deleting eventually

---

## 11. Known issues & risks

| # | Issue | Severity | Confidence |
|---|---|---|---|
| 1 | **Root logger writes synchronously to the network-mounted volume** from 55 call sites across `main.py`, none wrapped in `run_in_executor` (unlike the JSONL logs, which already are). Almost certainly the ongoing cause of the gateway's periodic "unresponsive" watchdog restarts. | Critical | High — confirmed by code inspection |
| 2 | **Single uvicorn worker** — any one blocked call anywhere freezes the entire service for every concurrent user. Not a drop-in fix: rate-limit/key state is in-process memory (§7), so multi-worker needs that state moved to a shared store first. | Critical | High — confirmed live |
| 3 | **Truncation-retry tiers are fixed absolute numbers**, not budgeted against remaining context — can request more output tokens than actually fit, causing a hard failure instead of a clean retry. Confirmed live in `vllm.log`. | Medium | High — confirmed in logs |
| 4 | **No graceful degradation when vLLM is restarted/unavailable** — a vLLM restart produces a ~7-minute window of raw, unhandled 500s to real users instead of a clean "retrying" response. | Medium | High — confirmed in logs |
| 5 | **Trial-key `expires` field appears to be stored but never checked** — `_resolve_key()` only checks `active`, not `expires`, so the documented 30-day self-service trial expiry may not actually be enforced. | Medium | Medium — inferred from code, not yet observed in production |
| 6 | **Hardcoded default admin console credentials** in source (used only if the `AVANIKO_ADMIN_USER`/`AVANIKO_ADMIN_PASS` env vars are unset). | Medium | High — confirmed in code |
| 7 | **Raw API keys are stored in the database** (`raw_key` column) despite documentation stating keys are "shown once, cannot be recovered" — anyone with direct DB access could read a customer's raw key. | Medium | High — confirmed in schema |
| 8 | **MariaDB's datadir sits on the same flaky network volume** as everything else. Its respawn loop only catches a process *exit*, not a *stall* — there's no timeout-based health check analogous to the gateway's watchdog. | Medium | Medium — inferred, not yet observed |
| 9 | **`main.py` is a single 3,260-line monolith** — auth, admin console, admin API, key management, chat, files, RAG, and extraction all in one file. A `main.py.monolith.bak` in the same directory suggests a modularization attempt was started and not completed. | Low (maintainability) | High — confirmed by inspection |
| 10 | **Overlapping endpoint pairs** — `/admin/keys` vs. `/admin-api/keys`, `/chat` vs. `/v1/chat/completions`, `/files/ask` vs. `/v1/files/{id}/ask` — serve genuinely different callers (see §5.2) but duplicate logic (e.g. validation/self-correction is implemented twice, once in `/v1/extract` and once in `/files/ask`), which is a real drift risk over time. | Low (maintainability) | High — confirmed by inspection |
| 11 | **Stale public URLs baked into several docs and a script** (`API_GUIDE.md`, `invoice_to_json.py`) point at a previous pod's RunPod proxy URL, which now 404s. | Low | High — confirmed live |

**Prioritized fix order** (highest impact, lowest effort first): (1) move the root logger off the network volume or wrap it async — closes the most likely cause of ongoing restarts; (2) cap truncation-retry tiers by remaining context budget; (3) add a clean 503 response path for vLLM-unavailable instead of raw 500s; (4) move rate-limit/key state to a shared store, then raise worker count; (5) add a stall-aware MariaDB health check.

---

## 12. Doc/reality gaps found while writing this document

- `RUNPOD_DEPLOYMENT.md` and `ISSUE_CONCURRENT_REQUESTS_TIMEOUT.md` still say `--max-num-seqs 8`; the live process runs with `--max-num-seqs 16`.
- `API_GUIDE.md` and `invoice_to_json.py` hardcode a stale proxy URL (`g9s7n0soow3h5q-...`); the live one is `s2f1q59mb9tg9r-...` — re-verify with `/health` after any pod restart rather than trusting a saved URL.
- `db_setup.sql` describes a schema (`avaniko_llm` DB) that the running application does not use; the real schema is in `avaniko_db.sql`.

---

## 13. Testing quick reference (Postman)

- **Base URL (public):** `https://s2f1q59mb9tg9r-7778.proxy.runpod.net` (re-verify after any restart)
- **Base URL (local, same pod):** `http://localhost:7778`
- **Header for every authenticated request:** `Authorization: Bearer ak-<your-key>`
- **`/v1/extract` body type:** `form-data`, never `raw`/JSON — it's a multipart endpoint (see §5.3 for the field table)
- **Never set `Content-Type` manually** on multipart requests — Postman generates the correct boundary automatically
- A ready-made Postman collection covering every `/v1/*` route (health, admin key management, chat, files, ask, extract) was generated earlier in this project's working session — import it and swap in your own key.
