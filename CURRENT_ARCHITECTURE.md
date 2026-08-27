# Avaniko AI Platform — Current Architecture
> Last updated: 2026-08-26 | Verified against live code + live running processes (not just docs)

> **Supersedes the architecture sections in `README.md`, `current.md`, and
> `PRODUCTION_ARCHITECTURE_REVIEW.md`.** Those describe an old two-tier
> `production/` + `avaniko-platform/` layout that no longer exists. The real
> system today is the single monolith below. Treat this file as the source of
> truth; the others are historical.

---

## 1. Hardware

| | |
|---|---|
| GPU | 1× NVIDIA RTX A6000, 49,140 MiB VRAM |
| Free VRAM (current, FP8 KV cache) | ~7.8 GB |
| Free VRAM (before FP8 KV cache) | ~5.0 GB |

**One GPU, one model instance.** A single copy of Qwen3.6-35B-A3B already uses
~43GB of the 49GB card, so there is no room for a second full model instance —
this rules out any "true" hardware-isolated multi-instance architecture
(e.g. separate GPU per queue type) without adding a second GPU.

---

## 2. Process Map

```
┌──────────────────────────────────────────────────────────────────┐
│ RunPod Pod (single container, /workspace persistent volume)       │
│                                                                     │
│  vLLM engine          gateway (monolith)      MySQL/MariaDB        │
│  port 7777            port 7778               port 3306            │
│  (no watchdog —       (watchdog auto-         (watchdog auto-      │
│   started once by      restart, ~3s)           restart, auto-      │
│   start_all.sh)                                 reinstall on       │
│                                                  container reset)   │
│                                                                     │
│  OCR service           Embedding service                           │
│  port 7780             port 7779                                   │
│  (watchdog auto-       (localhost only,                            │
│   restart —             no watchdog loop)                          │
│   PaddleOCR segfaults)                                              │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ https://<runpod-proxy>:7778
                              │
                        Client / SDK / dashboard
```

Everything is started/supervised by `/workspace/start_all.sh` (idempotent —
checks each service's `/health` before starting, safe to re-run after a pod
restart). Auto-restart loops:

- **Gateway** — `gateway_watchdog.sh` health-checks port 7778 every 15s;
  2 consecutive failures → force-kill + restart via `gateway/start.sh`.
  Exists because the gateway can freeze in kernel D-state on a blocked
  `/workspace` (network-mounted MooseFS) write without ever exiting on its own.
- **MySQL** — bash `while true` respawn loop; the network-mounted datadir has
  crashed `mariadbd` under write load before.
- **OCR** — bash `while true` respawn loop; PaddleOCR can segfault.
- **vLLM — no auto-restart.** If it dies, `start_all.sh` must be re-run
  manually (or a watchdog added — not present today).

---

## 3. The Gateway Is One File

`/workspace/gateway/main.py` — a single monolith, ~189KB, all routes and
business logic in one process (`uvicorn main:app --workers 1`). There is no
`routers/` package in active use (a `gateway/app/routers/` directory exists
but is not what's wired into the running app — `main.py` defines every route
directly). `/workspace/production/` (the old separate FastAPI app with
`routers/`, `services/`, etc. described in the stale docs) is legacy and not
what's running.

### Key endpoints (from `main.py`)

| Endpoint | Purpose |
|---|---|
| `POST /v1/chat/completions` | OpenAI-compatible chat (streaming + non-streaming, tool-calling) |
| `POST /v1/extract` | Invoice/document → structured JSON |
| `POST /v1/ask` | Q&A over an uploaded document |
| `POST /v1/files`, `GET /v1/files/{fid}`, `DELETE /v1/files/{fid}` | File upload/management |
| `POST /v1/files/{fid}/ask` | Ask a question against a specific stored file |
| `GET /v1/models`, `GET /v1/usage` | Model list, usage stats |
| `POST /auth/register`, `/auth/login`, `/auth/logout`, `/auth/signin`, `/auth/admin-login` | Auth |
| `GET/POST /admin-api/users`, `/admin-api/keys*` | Admin user/key management |
| `GET /admin/keys`, `/admin/keys/{id}/enable` | Legacy admin key endpoints |
| `POST /getkey`, `/signup/key` | Self-serve API key issuance |
| `GET /health` | Gateway + vLLM health |
| `GET /chat` | Built-in dev chat UI |
| `POST /files/ask` | Legacy streaming file-ask endpoint |

---

## 4. Model Serving (vLLM)

Launched by `start_all.sh` (persisted there so it survives pod restarts):

```
python -m vllm.entrypoints.openai.api_server \
  --model /workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4 \
  --served-model-name qwen3.6-35b \
  --host 127.0.0.1 --port 7777 \
  --dtype float16 \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.85 \
  --max-num-seqs 8 \
  --max-num-batched-tokens 4096 \
  --trust-remote-code \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --kv-cache-dtype fp8_e4m3
```

| Setting | Value | Notes |
|---|---|---|
| Model | Qwen3.6-35B-A3B, GPTQ-Int4 weights | Hybrid architecture — has recurrent Mamba/GDN layers, not pure attention |
| Public alias | `avaniko-1` (gateway) / `qwen3.6-35b` (vLLM's own name) | |
| Max context | 65,536 tokens | |
| Max concurrent sequences | 8 (vLLM) | Gateway scheduler caps its own admission at 7, see §5 |
| KV cache dtype | **fp8_e4m3** (as of 2026-08-26) | Was float16 (implicit `auto`) before today |
| KV cache scales | **Fixed 1.0**, not calibrated | `--calculate-kv-scales` is deprecated in vLLM 0.19.1 **and** vLLM auto-disables it for this model regardless — hybrid Mamba models can't run a reliable calibration pass because recurrent state is uninitialized during it. So this is effectively the same as vLLM's plain `fp8` auto/dynamic-scale mode, not true calibrated scales. |
| Prefix caching | Enabled | vLLM's automatic KV-block reuse across requests sharing a prompt prefix |
| vLLM version | 0.19.1 | |

**Why FP8 KV cache:** halves the per-token KV cache memory footprint, freeing
VRAM (roughly 5GB → 7.8GB free) without touching model weights (already
Int4-quantized separately). Frees headroom for more concurrent sequences /
longer effective context / safety margin — does **not** free enough VRAM for
a second model instance.

**Known rough edges hit getting this running** (for the next person who touches
these flags):
- Needs `ninja` on `PATH` for a one-time JIT kernel compile (flashinfer batch-prefill
  module) — symlinked `/workspace/venv/bin/ninja` → `/usr/local/bin/ninja`.
- This model's hybrid Mamba/attention layers force `block_size=2096`
  under FP8 KV cache ("Mamba cache align mode"), which is incompatible with
  the scheduler default `max_num_batched_tokens=2048` — must be raised
  (currently `4096`) or the engine fails an assertion at startup.

---

## 5. Request Scheduling — Soft Priority Queues

Since there's only one GPU and only one vLLM engine (no room for hardware
isolation — see §1), request-type isolation is implemented as **gateway-side
admission control**, not separate KV cache pools. The KV cache itself stays
one shared pool inside vLLM; this only decides which class of request gets
the next available concurrency slot.

Added 2026-08-26 in `gateway/main.py` (~line 826), class `_VLLMScheduler`:

```python
_VLLM_TOTAL_SLOTS = 7   # vLLM has --max-num-seqs 8; 1 slot headroom
_VLLM_RESERVED = {"CHAT": 2, "AGENT": 1, "DOCUMENT": 0}
```

- **CHAT** always has 2 slots it can claim immediately, even if DOCUMENT jobs
  are using everything else.
- **AGENT** (tool-calling chat requests) always has 1.
- **DOCUMENT** (extraction, map-reduce chunk calls, RAG) has no reserved
  minimum — it gets whatever's left, and yields newly-freed slots to
  CHAT/AGENT first if either is below its reserved minimum.
- **Not preemptive** — a request already generating can't be interrupted from
  outside vLLM. This only gates admission of new requests.

Every outgoing call to `VLLM_URL` (`http://localhost:7777`) goes through
`_vllm_sched.slot(queue_class)`. Call sites and their class:

| Function / endpoint | Queue class |
|---|---|
| `_llm()`, `_llm_retry_truncation()`, `_llm_sse()` (extraction, map-reduce, self-correct, RAG-ask) | `DOCUMENT` (default) |
| `_vllm_post()` | `CHAT` (default) |
| `_needs_web()`, `_detect_task()` (inline chat classifiers) | `CHAT` |
| `chat_completions()` | `AGENT` if request has `tools`/`tool_choice`, else `CHAT` |
| `/chat` (built-in dev UI) | `CHAT` |
| `/files/ask` (legacy streaming path) | `DOCUMENT` |

Full changelog: `/workspace/GATEWAY_QUEUE_ISOLATION_CHANGES.md`.

---

## 6. Request Flow — How Many LLM Calls Per Request

(Full detail: `/workspace/LLM_CALL_FLOW_AND_INVOICE_ARCHITECTURE_REPORT.md`)

**Single chat message:** usually **1–3 LLM calls** —
1. Optional: `_detect_task()` — cheap classifier call to pick a
   temperature/thinking preset (skipped for inline-image chat, which forces
   extraction mode directly).
2. Optional: `_needs_web()` — cheap classifier call to decide if live web
   context should be pulled in.
3. The real answer call.

No server-side agentic loop — if the client sends `tools`, the request is
passed through to vLLM's own tool-calling (`--enable-auto-tool-choice`,
`qwen3_coder` parser) and the class is `AGENT`, but the gateway isn't running
its own multi-step agent loop on top of that.

**Invoice/document → JSON (`POST /v1/extract`):** 1 client HTTP call.
Internally, **typically 1 LLM call** for a normal-sized document
(single-pass or vision-hybrid). Multiplies only when:
- the document is too large → map-reduce (1 call per chunk + reduce call(s)),
- `consistency > N` is requested → +N−1 cheap voting calls,
- deterministic validation fails → +1 self-correction retry.

Worst case ≈ `chunks + reduces + consistency_votes + 1`.

---

## 7. Auth / Secrets

- App-level auth: `x-api-key` header (own scheme) — `Authorization: Bearer`
  is also accepted at `/v1/chat/completions` for OpenAI SDK compatibility.
- JWT for the dashboard/admin login flows (`/auth/login`, `/auth/register`).
- Secrets live in `/workspace/.env` (`API_KEY`, `JWT_SECRET`) and
  `/workspace/.s3_env` (AWS creds for S3 backup push) — both are
  `chmod 600` and gitignored (`.s3_env` was added to `.gitignore`
  2026-08-26; previously only `*.env`-suffixed files were covered and
  `.s3_env` slipped through that pattern, though it was never actually
  committed).
- **Open item:** the AWS key in `.s3_env` is flagged in its own comment as
  already exposed in a chat transcript (2026-06-24) and needs rotation in
  the AWS IAM console — this environment has no AWS credentials configured
  to do that rotation programmatically, so it's still pending manual action.

---

## 8. File Reference

```
/workspace/
├── .env                 ← gateway API_KEY, JWT_SECRET
├── .s3_env               ← AWS creds for S3 backup (chmod 600, gitignored, key needs rotation)
├── start_all.sh          ← starts/supervises everything, idempotent, run after pod restart
├── gateway_watchdog.sh   ← health-checks + force-restarts the gateway
├── invoice_to_json.py    ← client-side script that calls /v1/extract
├── ocr_server.py         ← PaddleOCR service (port 7780)
├── embed_server.py       ← embedding service (port 7779)
│
├── gateway/               ← ✅ LIVE — the real production app
│   └── main.py            ← the monolith: every route, the vLLM scheduler, auth, everything
│
├── production/            ← ⚠️ LEGACY — old separate FastAPI app, not what's running
├── avaniko-platform/      ← ⚠️ LEGACY — old two-tier public API layer, never deployed, likely stale
│
├── models/Qwen3.6-35B-A3B-GPTQ-Int4/   ← model weights served by vLLM
│
├── CURRENT_ARCHITECTURE.md                              ← this file
├── GATEWAY_QUEUE_ISOLATION_CHANGES.md                    ← priority-queue scheduler changelog
├── LLM_CALL_FLOW_AND_INVOICE_ARCHITECTURE_REPORT.md      ← full call-flow trace, chat + extract
├── EXTRACT_VISION_OCR_PIPELINE.md                        ← OCR/vision pipeline detail (dated, verify against code)
├── README.md, current.md, PRODUCTION_ARCHITECTURE_REVIEW.md, AVANIKO_FULL_REPORT.md
│                                                          ← ⚠️ STALE — describe the old two-tier layout, kept for history only
```

---

## 9. Known Open Issues

| Priority | Issue | Action needed |
|---|---|---|
| 🔴 HIGH | AWS key in `.s3_env` was exposed in a chat transcript (2026-06-24) | Rotate in AWS IAM console — needs a human with AWS access, not doable from this environment |
| 🟡 MED | vLLM has no auto-restart watchdog (unlike gateway/MySQL/OCR) | If it dies, requires manually re-running `start_all.sh` |
| 🟡 MED | `gateway/app/routers/` package exists but isn't wired into the running app | Either wire it up or remove it — currently dead code sitting next to the real monolith, confusing for anyone reading the repo |
| 🟢 LOW | `README.md` / `current.md` / `PRODUCTION_ARCHITECTURE_REVIEW.md` describe a two-tier layout that no longer exists | Should be updated or archived so they stop misleading readers |
