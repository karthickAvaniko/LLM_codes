# Avaniko AI Platform — Architecture & Workflow (Interview Q&A)

A full walkthrough of the self-hosted LLM platform running on this box, written as
interview-style questions and answers: what runs, which frameworks/packages,
and how a request flows end to end.

---

## 1. High-Level Architecture

**Q: What is this platform, in one sentence?**
A: A self-hosted, OpenAI-compatible AI API — branded "Avaniko AI" — built on an
open-weight LLM served by vLLM, wrapped by a FastAPI gateway that adds auth,
rate limiting, billing/usage tracking, file upload + OCR, and RAG over
documents.

**Q: What are the moving parts, and what port does each run on?**
A:
| Service | Port | Framework | Purpose |
|---|---|---|---|
| Gateway (`main.py`) | 7778 | FastAPI + Uvicorn | Public-facing API: auth, routing, RAG, files, billing |
| vLLM | 7777 (localhost only) | vLLM OpenAI-server | Actual LLM inference |
| Embedding service | 7779 (localhost only) | FastAPI + sentence-transformers | Text → vector for RAG retrieval |
| OCR service | 7780 (localhost only) | FastAPI + PaddleOCR | Scanned PDF / image → text |
| MySQL (MariaDB) | 3306 (localhost only) | MariaDB | API keys, users, sessions, usage logs |
| nginx | 8001 (and others) | nginx | Reverse proxy / port fronting for some services |

**Q: Why split OCR and embeddings into their own processes instead of running
everything inside the gateway?**
A: Isolation. PaddleOCR is known to segfault occasionally on this build; if it
lived inside the main gateway process, a crash would take the whole API down.
Running it as its own process under an auto-restart loop (`while true; do
uvicorn ...; sleep 3; done`) means only OCR restarts — chat, RAG, and auth stay
up. Same reasoning for embeddings: a separate lightweight CPU-only process
that the gateway calls over HTTP.

**Q: Draw the request path for a typical chat call.**
A:
```
client
  → gateway :7778  (auth check, rate limit, logging)
      → vLLM :7777  (OpenAI-compatible /v1/chat/completions)
      ← streamed tokens
  ← gateway streams response back to client (SSE)
      → gateway writes access.jsonl + requests.jsonl
      → gateway flushes usage counters to MySQL every 15s
```

**Q: Draw the request path for "ask a question about my uploaded PDFs" (RAG).**
A:
```
client → POST /v1/files (upload PDF)
  gateway → extract_pages() → if scanned, calls OCR :7780
  gateway → embed_server :7779 → chunk vectors stored
client → POST /v1/ask {"question": "..."}
  gateway → embed_server :7779 (embed the question)
  gateway → similarity search over stored chunk vectors → top_k hits
  gateway → vLLM :7777 with only the top chunks (bounded token cost, never overflows context)
  ← answer + sources (file, page, score) returned to client
```

---

## 2. Frameworks & Packages

**Q: What's the serving framework for the LLM itself, and why that one over
alternatives like Text Generation Inference (TGI) or plain HuggingFace
`transformers`?**
A: **vLLM** (`vllm==0.19.1`), chosen for its PagedAttention memory manager,
continuous batching (so concurrent requests share GPU throughput instead of
queuing), an OpenAI-compatible `/v1/chat/completions` endpoint out of the box,
and built-in support for tool-calling / reasoning-token parsers matching the
Qwen model family.

**Q: What's the exact model, and what does "GPTQ-Int4" mean?**
A: `Qwen3.6-35B-A3B-GPTQ-Int4` — a 35B-parameter (mixture-of-experts, ~3B
active) Qwen model, **GPTQ-quantized to 4-bit weights**. GPTQ is a
post-training quantization scheme; running int4 instead of fp16/bf16 cuts VRAM
use roughly 4x, which is what lets a 35B model fit and serve concurrently on a
single 48 GB RTX A6000 alongside everything else.

**Q: What's the full Python/ML package stack?**
A:
- **torch** 2.10.0 (cu128 build), **torchvision**, **torchaudio** — CUDA 12.8
- **vllm** 0.19.1 — inference server
- **transformers** 4.57.1 — tokenizers/model glue code vLLM depends on
- **triton** 3.6.0 — GPU kernel compilation (vLLM's custom kernels)
- **fastapi** + **uvicorn** — both the gateway and the two sidecar services
- **sentence-transformers** (`all-MiniLM-L6-v2`, 384-dim, CPU) — embeddings for RAG
- **paddlepaddle-gpu** + **paddleocr** — OCR engine
- **pymupdf** (imported as `fitz`), **python-docx**, **openpyxl**, **pillow** — document/text extraction for PDF, Word, Excel, images
- **pymysql** — MySQL client from Python
- **httpx** — gateway → vLLM/OCR/embed internal HTTP calls
- **pydantic** — request/response models (FastAPI's native validation)
- **hf_transfer**, **huggingface_hub[cli]** — fast model downloads from Hugging Face

**Q: Why FastAPI for the gateway instead of Flask/Django?**
A: Native `async`/`await` support (needed to proxy streaming responses from
vLLM without blocking), automatic request validation via Pydantic, and
built-in `StreamingResponse`/SSE support used for both chat streaming and
RAG-answer streaming.

**Q: What database, and why MySQL/MariaDB over Postgres or SQLite?**
A: MariaDB (MySQL-compatible), storing three main tables: `api_keys`,
`chat_history`, `usage_logs` (see `db_setup.sql`). Nothing here needs
Postgres-specific features; MySQL was simply the team's default choice, and
`pymysql` gives a pure-Python client with no extra system deps. The gateway
keeps API keys cached in memory and flushes usage counters (`requests`,
`tokens_in/out`, `last_used`) to MySQL every 15 seconds rather than hitting the
DB on every single request.

---

## 3. Inference Configuration

**Q: What vLLM flags matter most in production, and why?**
A: From `start_all.sh`:
- `--max-model-len 32768` — hard context cap (32k tokens)
- `--gpu-memory-utilization 0.85` — leaves headroom so vLLM doesn't OOM the A6000
- `--max-num-seqs 8` — max concurrent sequences batched together
- `--enable-prefix-caching` — reuses KV cache across requests sharing a prompt prefix (e.g. repeated system prompt), cutting latency on multi-turn chats
- `--enable-auto-tool-choice` + `--tool-call-parser qwen3_coder` — lets the
  model emit structured tool/function calls in Qwen's expected format
- `--reasoning-parser qwen3` — separates the model's internal reasoning
  tokens from the final answer in the API response
- `--trust-remote-code` — required because Qwen ships custom modeling code

**Q: How does the gateway keep prompts from ever exceeding the model's context
window?**
A: It computes a conservative character budget before calling vLLM:
`CONTEXT_TOKENS (32768) - max_tokens_requested - CTX_MARGIN (800)`, converted
to characters at ~1.7 chars/token (deliberately conservative — code and Tamil
text can tokenize denser than plain English). If a request would still
overflow, the gateway raises a `ContextOverflow` and retries with a trimmed
prompt rather than letting vLLM hard-reject it.

**Q: How does RAG keep token cost constant regardless of how many documents a
user has uploaded?**
A: `/v1/ask` never sends whole documents to the LLM. It embeds the question,
does a similarity search over pre-computed chunk vectors for *all* of the
user's ready documents, takes only the top-`k` (≤10) highest-scoring chunks,
and sends just those to vLLM. Whether the user has 1 document or 200, the
prompt size — and therefore cost/latency — stays roughly constant.

---

## 4. API Surface

**Q: What are the main public endpoints and what does each do?**
A:
- `POST /v1/chat/completions` — OpenAI-compatible chat, streaming or not (proxies to vLLM)
- `POST /v1/files` — upload a document (PDF/image/docx/xlsx/etc.), extracted + chunked + embedded in the background
- `POST /v1/files/{id}/ask` — ask about one specific uploaded file
- `POST /v1/ask` — RAG: ask a question across *all* of a key's ready documents
- `POST /v1/extract` — batch mode: up to 20 files in one call, same question asked of each, processed concurrently (vLLM batches the GPU work so 10 files barely take longer than 1)
- `GET /v1/models`, `GET /v1/usage` — model listing / usage stats
- `POST /auth/register`, `/auth/login`, `/auth/signin` — account + session management (accounts restricted to `@avaniko.com` emails)
- `/admin-api/*`, `/admin/keys*` — admin key/user management
- `GET /health` — liveness probe used by `start_all.sh` and monitoring

**Q: How does file upload → OCR → RAG fit together for a scanned PDF?**
A: `POST /v1/files` calls `extract_pages()`; if the PDF has no embedded text
layer (i.e., it's a scan), that function calls the OCR sidecar (`:7780`,
PaddleOCR) page by page. Extracted text per page is chunked and sent to the
embedding sidecar (`:7779`) for vectorization, then stored under
`gateway/files/{id}.pages.json`. From then on, `/v1/ask` and
`/v1/files/{id}/ask` search those pre-computed vectors — OCR only ever runs
once per document, not once per question.

---

## 5. Auth, Rate Limiting & Multi-Tenancy

**Q: How does API-key auth work?**
A: Keys are SHA-256 hashed before storage/comparison (never stored or logged
in plaintext). A special master admin key (auto-generated on first boot into
`gateway/.api_key`, or overridden by the `AVANIKO_API_KEY` env var) bypasses
per-key limits. All other keys are looked up by hash in an in-memory cache
backed by MySQL.

**Q: What limits are enforced per key?**
A: A sliding-window requests-per-minute limit (default 60 rpm) and a
UTC-day request quota (default 5000/day), each independently configurable per
key. Trial/self-service signups get tighter limits (10 rpm / 250 per day / 30
days) if self-service signup is enabled via `AVANIKO_SELF_SIGNUP=1`.

**Q: Is there brute-force protection on auth?**
A: Yes — failed-auth attempts are tracked per client IP in a 60-second sliding
window (`AUTH_FAIL_LIMIT = 20`); signup attempts per IP are separately capped
per day.

**Q: How is the underlying model kept invisible to end customers?**
A: A fixed system/identity prompt is prepended server-side identifying the
assistant only as "Avaniko AI," instructing it never to reveal the underlying
model, vendor, or training organization even if directly asked. The internal
model name (`qwen3.6-35b`) is only ever used for the vLLM API call; the
public-facing model id everywhere else is `avaniko-ai`.

---

## 6. Storage & Logging

**Q: What gets logged, and where?**
A: Two parallel JSONL logs in `/workspace/logs/`:
- `access.jsonl` — every HTTP request including failed auth (401s)
- `requests.jsonl` — content-level logs: question/answer previews, OCR
  previews, RAG sources — **truncated to 1000 chars per string field** so full
  document contents never bloat the log
Both rotate at fixed size limits (200 MB) instead of growing unbounded.
Separately, `gateway_app.log` is a rotating file handler (50 MB × 5 backups)
for structured application logs.

**Q: What's persisted in MySQL vs. kept only in memory?**
A: MySQL is the source of truth for `api_keys`, `users`, `sessions`, and usage
counters. The gateway keeps a hot in-memory cache of all API keys (for
zero-latency auth checks) and only flushes dirty usage counters
(`requests`, `tokens_in/out`, `last_used`) back to MySQL every 15 seconds — an
explicit tradeoff of "usage stats can lag up to 15s" for "auth never blocks on
a DB round-trip."

**Q: Is there a backup strategy?**
A: Yes — a background loop in `start_all.sh` runs `backup.sh` once every 24
hours, keeping 14 days of backups.

---

## 7. Deployment & Ops

**Q: How is the whole stack brought up after a restart?**
A: `bash /workspace/start_all.sh` — it's idempotent (checks `/health` on each
service before starting it, so re-running it is safe), and starts, in order:
vLLM (7777) → MariaDB → OCR sidecar (7780, under an auto-restart loop) →
embedding sidecar (7779) → gateway (7778) → daily backup loop. It then polls
vLLM's `/health` for up to 10 minutes (model load time) before printing final
status.

**Q: Why does vLLM sometimes take minutes to become healthy after a restart?**
A: Loading a 35B-parameter model's weights (even at int4) from disk into GPU
memory and initializing the KV cache allocator takes real time —
`start_all.sh` explicitly waits up to 60×10s = 10 minutes for `/health` to
return 200 before considering the boot sequence complete.

**Q: What's the hardware this runs on?**
A: A single NVIDIA RTX A6000 (48 GB VRAM), CUDA 12.8 driver 570.211.01. At
`--gpu-memory-utilization 0.85`, vLLM is allowed to claim up to ~41 GB of that
for weights + KV cache, leaving headroom for the other GPU-touching process
(none currently — OCR and embeddings both run on CPU).

**Q: Is there more than one setup script, and which one is authoritative?**
A: `setup.sh` is an older one-shot installer (different ports: vLLM on 1111,
gateway on 2222, `--enforce-eager`, no prefix caching/tool-calling flags).
`start_all.sh` is the current, actively-used startup script (vLLM :7777,
gateway :7778) with health-check idempotency and the full sidecar stack — it's
the one referenced in its own header comment as "Run this after a pod
restart."

---

## 8. Quick Reference

**Q: If I only remember three things about this stack, what should they be?**
A:
1. **vLLM serves the model; FastAPI gateway serves the product.** vLLM never
   talks to the internet directly — it's proxied, authenticated, rate-limited,
   and branded by the gateway.
2. **RAG cost is bounded by chunk retrieval, not document count** — the
   embedding sidecar + top-k search is what makes "ask across all your
   documents" cheap regardless of how much has been uploaded.
3. **Everything non-core (OCR, embeddings) is isolated in its own process**
   specifically because PaddleOCR is crash-prone — this is a deliberate
   reliability boundary, not incidental structure.
