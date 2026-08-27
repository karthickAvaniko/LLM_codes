# Avaniko AI Platform — LLM Call Flow & Invoice Extraction Architecture Report
> Verified directly against the live code in `/workspace/gateway/main.py` (last modified 2026-08-25 — this is the ONE live gateway; `/workspace/production/` does **not exist on this pod**, it's a stale path from old docs). All line numbers refer to `/workspace/gateway/main.py` unless noted.

---

## 0. Correction to existing docs

`README.md`, `current.md`, `PRODUCTION_ARCHITECTURE_REVIEW.md` describe a two-tier `production/` + `avaniko-platform/` split with ports 1111/2222/8888. **That no longer matches reality.** The system actually running is the single monolith described in `RUNPOD_DEPLOYMENT.md` and `gateway/start.sh`:

| Service | Port | Bind | Started by |
|---|---|---|---|
| vLLM (Qwen3.6-35B-A3B-GPTQ-Int4, served as `qwen3.6-35b`) | 7777 | 127.0.0.1 (private) | `start_all.sh` |
| MySQL/MariaDB (`avaniko_llm`/`avaniko` db) | 3306 | 127.0.0.1 | `start_all.sh` (auto-restart loop) |
| OCR service (PaddleOCR, `ocr_server.py`) | 7780 | 127.0.0.1 (private) | `start_all.sh` (auto-restart loop) |
| Embedding service (`embed_server.py`, sentence-transformers) | 7779 | 127.0.0.1 (private) | `start_all.sh` |
| **Gateway** (`gateway/main.py`, FastAPI, single `uvicorn` worker) | **7778** | 0.0.0.0 (only port exposed publicly) | `gateway_watchdog.sh` (health-checks + force-restarts) |

Only port 7778 is meant to be public. `.env` at `/workspace/.env` still shows the *old* 1111/2222/8888 scheme — that file is stale/unused; `start_all.sh` hardcodes 7777/7778/7779/7780 directly and ignores `.env`.

**⚠️ Security note (out of scope of the architecture question but found during this review, flagging per instructions not to miss anything):** `/workspace/.env`, `/workspace/.s3_env`, and `/workspace/invoice_to_json.py` all contain live plaintext credentials (admin password, JWT secret, AWS keys, an API key). `.s3_env` even has a comment admitting the AWS key "was exposed in a chat transcript on 2026-06-24" and should be rotated but apparently hasn't been. This report does not reproduce those values — recommend rotating them and moving them out of files that live in `/workspace` (which is backed up to S3 and mirrored).

---

## 1. Deployment — how the LLM is actually started

`bash /workspace/start_all.sh` does, in order (each step is idempotent/skips if already running):

1. **vLLM** — `python -m vllm.entrypoints.openai.api_server` on port 7777, model `/workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4`, `--max-model-len 65536`, `float16`, `--gpu-memory-utilization 0.85`, `--max-num-seqs 8`, prefix caching + tool-call parsing enabled. Note: `main.py` line 2796 (`CONTEXT_TOKENS = 65_536`) matches the 65536 launch flag — but `RUNPOD_DEPLOYMENT.md` still says 32768/16384 in places; those are stale, **65536 is current**.
2. **MySQL** — wrapped in a `while true` respawn loop because the network-mounted `/workspace` volume has crashed `mariadbd` under write load before.
3. **OCR service** (`ocr_server.py`, PaddleOCR) — also in a respawn loop; PaddleOCR is known to segfault. Runs under `/workspace/gateway/venv` specifically (needs `numpy==1.26.4`, not the numpy 2.x in the main venv).
4. **Embedding service** (`embed_server.py`) — plain start, no watchdog.
5. **Gateway** — NOT started directly; `gateway_watchdog.sh` is launched, which health-checks `main.py`'s `uvicorn` process and force-kills/restarts it if it freezes (observed to hang in kernel D-state on blocked `/workspace` writes without ever exiting on its own).
6. **Daily backup loop** — `backup.sh` every 24h, 14-day retention, dumps MySQL + code + keys to `/workspace/backups`.

Gateway itself (`gateway/start.sh`) runs as `uvicorn main:app --host 0.0.0.0 --port 7778 --workers 1 --loop asyncio --timeout-keep-alive 300`. **Single worker, single process** — all concurrency inside one Python asyncio event loop; parallelism across requests comes from `httpx.AsyncClient` calls to vLLM and `asyncio.gather`, not OS processes.

---

## 2. How one LLM call actually works (the mechanical layer)

Two internal helpers wrap every call to vLLM's OpenAI-compatible endpoint at `http://localhost:7777/v1/chat/completions`:

- **`_llm()`** (line 831) — the base call. Fixed `temperature=0.0`, `seed=42` (`EXTRACTION_SEED`), thinking mode off, optional `response_format` for vLLM guided-decoding (constrains output to a caller-supplied JSON Schema). Raises `ContextOverflow` if vLLM reports "maximum context length", raises `OutputTruncated` if `finish_reason == "length"`. Every call is logged to `EXTRACTION_LOG` (prompt/completion/total tokens, truncation flag). **Comment at line 825-828 states this function is only ever used for document-grounded work (extraction, map-reduce chunks, self-correction, RAG) — never the free-form `/v1/chat/completions` endpoint**, which builds its own request body inline (see §3).
- **`_llm_retry_truncation()`** (line 867) — wraps `_llm()` with escalating `max_tokens` tiers (default → 8192 → up to the model's remaining context budget) when a response keeps getting cut off mid-JSON. Tiers are capped by estimated prompt size so a retry never asks vLLM for more tokens than the 65,536-token window has left.

Auth to vLLM: none — it's `127.0.0.1`-only, no key needed. Auth to the *gateway* (client-facing) is `x-api-key`/`Authorization: Bearer` checked in the `require_api_key` middleware (line 358) against MySQL-backed keys, with rate limiting and IP-based auth-fail blocking.

Token budgeting constants: `MAX_TOKENS_CAP = 8192` (per-request output cap on `/v1/chat/completions`), `MAX_INPUT_CHARS = 60_000` / `CONTEXT_TOKENS = 65_536` / `CTX_MARGIN = 800`, `SINGLE_SHOT_CHARS = 80_000` (doc pipeline single-pass threshold), `CHUNK_CHARS = 70_000`, `MAP_CONCURRENCY = 4`.

---

## 3. Chat — how many LLM calls happen per single chat message?

**Endpoint:** `POST /v1/chat/completions` (line 3116, the primary one; `POST /chat` at line 3269 is a thin SSE wrapper the HTML UI uses, same underlying logic path).

This is **NOT always exactly one LLM call.** The count depends on the request:

| Scenario | LLM calls | What happens |
|---|---|---|
| Plain text chat, `task` explicit or obviously short/simple, no images, no web-search trigger | **1** | Straight proxy to vLLM `/v1/chat/completions` with system-prompt injection (identity + date) and message trimming. |
| Plain text chat, `task="auto"` (the default) and message doesn't trip the >4000-char shortcut | **2** | +1 hidden classifier call (`_detect_task()`, line 3080) — a tiny 4-token completion that labels the message `coding`/`reasoning`/`extraction`/`classification`/`chat` to pick temperature/thinking-mode presets. Then the real answer call. |
| Chat message contains an inline image (`image_url` content part) | **2 (or 3)** | `_resolve_images()` (line 2820) OCRs the image via the OCR service (not an LLM call) then attaches it as a real vision part; task is force-set to `extraction` (skips the classifier — so no `_detect_task` call here), giving **1** answer call. If `web_search` also fires, +1 (see below). |
| `task="auto"` AND the model decides the question needs live info (`web_search` unset/`"auto"`) | **3** | classifier call (`_detect_task`) + `_needs_web()` classifier call (line 2917, another tiny 3-token yes/no call) + the real answer call. Web search itself (`_web_search_sync`, DuckDuckGo via `ddgs`) is a plain HTTP search, not an LLM call. |
| `web_search: true` forced by client | **2** | skip `_needs_web` classifier, still pay `_detect_task` unless `task` given explicitly, +1 answer call. |
| Request carries `tools`/`tool_choice` (agentic client — Continue/Cline/MCP) | **1** (from the gateway's perspective) | "Agent passthrough" mode (line 3137): gateway does NOT call any classifier, does NOT do web-search injection, does NOT rewrite thinking mode — it forwards the body to vLLM essentially untouched (only strips non-OpenAI params, caps `max_tokens`). Any additional back-and-forth tool-call loop is driven by the **client**, not the gateway — the gateway has no server-side agent loop of its own. |
| Context overflow (`"maximum context length"` from vLLM) | **+1 retry per overflow, up to 4 attempts (line 3209)** | Non-streaming path also retries via `_vllm_post`; streaming path shrinks `_fit_messages()` budget by 0.6x and retries in-place. |

**So: a single chat message is usually 1–3 real LLM calls to vLLM** (1 answer call + up to 2 tiny classifier calls), never a multi-step "agent" reasoning loop server-side — there is no server-side ReAct/tool-execution loop in the gateway. The only place multiple *substantive* answer-generating calls happen for chat is the map-reduce path, but that's only reachable through `/v1/files/{id}/ask` and `/v1/ask` (document Q&A), not the raw `/v1/chat/completions` text path, since that path caps input at ~60K chars via `_fit_messages()` rather than chunking.

**Note on classifier calls:** both `_detect_task` and `_needs_web` hit the *same* vLLM server as the main answer (`http://localhost:7777`), just with `max_tokens=3` or `4`. They are real, separate HTTP round-trips and separate vLLM inference calls — vLLM batches them on the GPU alongside other traffic, but each is counted in `usage`/logs as its own request. **These are NOT counted/recorded in `_record_tokens`** (`_llm()`'s bookkeeping) — they bypass `_llm()` entirely and call `httpx` directly, so their token cost does not appear in the per-key usage stats in MySQL. This means the usage numbers a customer sees under-count actual vLLM load slightly (by the classifier calls).

---

## 4. Invoice → JSON — how many API/LLM calls per document?

There are **three different endpoints** a client can use for document extraction, all sharing the same core pipeline functions (`extract_pages`, `answer_document`, `_llm_retry_truncation`, `validate_extraction`) but with different call counts and guarantees:

### 4a. `POST /v1/extract` (line 2595) — the one `invoice_to_json.py` uses, and the recommended path
**Client side: ONE HTTP call**, even for a batch of up to `MAX_BATCH_FILES = 20` files (processed concurrently, `asyncio.Semaphore(5)`). Internally, **per file**, the LLM call count is variable:

1. Text/image extraction (`extract_pages` + `extract_page_images`) — **not an LLM call**, it's PyMuPDF + the OCR microservice on 7780 (page-by-page: OCR only triggers if native PDF text on a page is <300 chars).
2. **Primary extraction pass** — exactly **1 LLM call**, either:
   - `vision_hybrid`: page images + OCR text sent together (only if ≤`MAX_VISION_PAGES=10` pages AND text ≤`SINGLE_SHOT_CHARS=80_000` chars), OR
   - `single_pass` text-only, OR
   - `map_reduce` (see §4c below) if the doc is too big or the single-pass output gets truncated — this multiplies the call count.
3. **Optional self-consistency** (`consistency` param, 1–5, default 1): if `consistency > 1`, the full pass above runs once, then **`(consistency − 1)` additional cheap calls** (`_extract_critical_fields`, `max_tokens=512`) that re-extract *only* invoice_number/subtotal/tax/total and majority-vote them into the primary result. This is deliberately NOT `consistency` full re-extractions — it's 1 full pass + N-1 tiny 4-field passes.
4. **Validation is deterministic code, not an LLM call** (`validate_extraction()`, line 2279 — arithmetic checks: line items sum to subtotal, tax+subtotal=total, vendor field present, etc.).
5. **Self-correction, conditional**: if validation fails, **+1 LLM call** (`_self_correct()`, line 2506) that's shown the previous answer + the exact validation complaints and asked to fix only those fields. No second self-correction attempt if this one still fails — the result is returned uncorrected with `validation.corrected: false`.
6. **Optional canonicalize** (`canonicalize=true` param): field-name normalization via `canonicalize_fields()` — uses the embedding service (7779) for semantic field-name matching, not an LLM call.

**So for the common case (single-pass, no consistency voting, validation passes first try): 1 LLM call per invoice.** Worst case (map_reduce needed + consistency=5 + self-correct needed) can be 1(map chunks, N calls) + 1(reduce) + 4(critical-field votes) + 1(self-correct) ≈ **N+6 LLM calls for one document.**

### 4b. `POST /v1/files/{id}/ask` (line 1756) — two-call client flow
Requires the client to first `POST /v1/files` (upload, gets queued for background extraction — OCR/parsing only, no LLM yet) and **poll** `GET /v1/files/{id}` until `status: "ready"`, **then** `POST /v1/files/{id}/ask` with a question. So this is **2 client-side API calls minimum** (upload + ask), vs. `/v1/extract`'s single call. Internally the `ask` call runs `answer_document()` (1 LLM call if single-pass fits, more if map_reduce) plus a conditional self-correct call if the question implies JSON (`_wants_json()`) and validation fails — same self-correction mechanism as `/v1/extract`. No consistency-voting option on this endpoint (that's `/v1/extract`-only). Response includes `llm_calls` field so the actual count is visible to the caller per-request.

### 4c. `POST /files/ask` (line 3328, legacy/UI endpoint) — one call, streaming, progress events
Single HTTP call (multipart upload + question), but streams SSE progress events (`"Reading documents…"`, elapsed time) because RunPod's proxy silently cuts idle connections around ~100s and big scanned PDFs can OCR for minutes. Same `answer_document()` pipeline underneath, so the same LLM-call variability as above (1 call if single-pass; map_reduce for large docs).

### Map-reduce, multi-invoice / large PDFs (all three endpoints funnel into `answer_document()`, line 996)
- If total page-text ≤ `SINGLE_SHOT_CHARS` (80K chars): **1 LLM call.**
- Otherwise: pages are grouped into chunks ≤ `CHUNK_CHARS` (70K chars) each, and **every chunk gets its own LLM call in parallel** (`_map_chunks`, bounded to `MAP_CONCURRENCY=4` concurrent), each told "you only see some pages, write NOT FOUND for anything missing." Then a **reduce call** merges all partial findings into one final answer. For very large documents (500+ pages worth of partials >60K chars combined), reduction is **hierarchical** — merged in groups of 5 with additional intermediate reduce calls until small enough for one final combine call. So call count = `len(chunks) + (hierarchical reduce rounds) + 1 final reduce`.
- **Multi-invoice PDFs**: there is no dedicated "split into N separate invoices" step — a multi-invoice PDF is handled as one document whose pages get OCR'd/chunked like any other; the extraction prompt is left open-ended ("structure the JSON to fit what this document actually contains") rather than the pipeline enforcing one-invoice-per-response. `V1_EXTRACT_MULTI_INVOICE_AND_TOKEN_LOG.md` documents an earlier iteration of this problem — worth a follow-up read if multi-invoice correctness is a current concern, since it wasn't independently re-verified against today's code in this pass.

**Vision hybrid is capped**: only used ≤10 pages AND ≤80K chars of text — bigger invoices/scans silently fall back to text-only map_reduce (loses stamp/logo/handwriting cross-checking, gains map_reduce's robustness to context overflow).

---

## 5. Single unified API, or separate paths for chat vs. invoice?

**Both.** They share the same underlying transport (`_llm`/`_llm_retry_truncation` → vLLM) but are exposed as genuinely different endpoints with different guarantees, and there is real, intentional code duplication between them:

- **Chat** lives in `/v1/chat/completions` (+ `/chat` UI wrapper) — free-form, streaming-first, classifier-driven preset selection, no document pipeline, no validation, no self-correction. Comment at line 825-828 explicitly documents that `_llm()` (the deterministic, validated pipeline) is *never* used here.
- **Invoice/document extraction** lives in `/v1/extract`, `/v1/files/*`, `/files/ask` — deterministic (`temperature=0`, fixed `seed=42`), validated (`validate_extraction`), self-correcting, with three separate endpoints trading off "one call, no cache" (`/v1/extract`) vs. "upload once, ask many times" (`/v1/files`) vs. "one call, streaming progress, legacy" (`/files/ask`).
- **The one deliberate bridge between them**: if a client sends an image inline to `/v1/chat/completions` (`_resolve_images`, line 2820), the gateway detects it, force-switches `task` to `extraction`, and injects `DOC_SYSTEM + EXTRACTION_RULES` — the *same* system prompt the dedicated extraction endpoints use — specifically because an earlier version of this path produced inconsistent JSON call-to-call without it (documented in the code comment at line 2830-2833). So inline-image chat is chat-shaped at the HTTP layer but extraction-shaped internally once an image is present.
- A standalone script, `/workspace/invoice_to_json.py`, is a thin CLI wrapper that just calls `POST /v1/extract` — it is not a separate code path, it's a client of the same endpoint documented in §4a. Its own docstring explicitly warns not to switch it to `/v1/chat/completions` because that path is less consistent.

**`invoice_to_json.py` output on disk** (`STG-0499_output.json`, `V0020990-10370477_extracted*.json`) confirms this is actively being run/tested against real sample invoices in `/workspace` (`STG-0499.pdf`, `V000187-INV91679.pdf`, `V000200-118218.pdf`, `V00V534-HY11041-1 18I.pdf`).

---

## 6. Quick-reference: call counts

| Action | Client-side HTTP calls | Internal LLM calls (typical / worst-case) |
|---|---|---|
| Plain chat message, task auto-detected | 1 | 2 (classifier + answer) |
| Chat message with explicit `task=` | 1 | 1 |
| Chat message needing live web info | 1 | 3 (task classifier + web-need classifier + answer) |
| Chat message with inline image | 1 | 1 (classifier skipped, forced to extraction) |
| Agentic/tool-call chat request | 1 (+ client-driven follow-ups, not server-side) | 1 per turn, gateway does no server-side looping |
| `/v1/extract`, 1 file, default settings | 1 | 1 (single-pass/vision) up to `N chunks + reduces + 1` (map_reduce) |
| `/v1/extract`, 1 file, `consistency=5` | 1 | +4 small critical-field votes on top of the above |
| `/v1/extract`, N files (≤20) | 1 | sum of per-file counts above, processed with concurrency 5 |
| `/v1/files` + `/v1/files/{id}/ask` | 2 (upload, then ask) | same per-document logic as `/v1/extract`, minus consistency voting |
| `/files/ask` (legacy streaming) | 1 (SSE) | same per-document logic |

---

*Report generated 2026-08-26 by tracing `/workspace/gateway/main.py` line-by-line against the endpoints in §1–5, cross-checked against `RUNPOD_DEPLOYMENT.md`, `start_all.sh`, `gateway/start.sh`, `.env`, `invoice_to_json.py`, and sample extraction outputs already in `/workspace`. Existing docs (`README.md`, `current.md`, `PRODUCTION_ARCHITECTURE_REVIEW.md`) describe an older `production/` + `avaniko-platform/` two-tier layout that does not exist on this pod — treat this report and the live `gateway/` code as current, and those three files as historical/stale.*
