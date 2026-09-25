# Avaniko AI Platform — Current Architecture
> Last updated: 2026-09-24 | Verified against live code + live running processes (not just docs)

> **Supersedes the architecture sections in `README.md`, `current.md`, and
> `PRODUCTION_ARCHITECTURE_REVIEW.md`.** Those describe an old two-tier
> `production/` + `avaniko-platform/` layout that no longer exists. The real
> system today is the single monolith below. Treat this file as the source of
> truth; the others are historical. This revision also supersedes the
> 2026-08-26 version of this file — GPU hardware, the model checkpoint, the
> vLLM launch flags, the scheduler slot counts, and the public-exposure path
> have all changed since then.

---

## 1. Hardware

| | |
|---|---|
| GPU | 1× NVIDIA RTX PRO 6000 Blackwell Server Edition, 97,249 MiB VRAM (upgraded from the original RTX A6000 48GB — see `A100_80GB_UPGRADE_SIZING_REPORT.md` for the sizing history) |
| VRAM in use (model + reserved KV cache, `--gpu-memory-utilization 0.85`) | ~86 GB |
| vLLM's own reported KV-cache capacity at this utilization | 4,104,426 tokens ≈ 62.6x concurrency headroom for 65,536-token requests |

**One GPU, one model instance**, same as before — still no hardware isolation
between request classes; isolation is done gateway-side (§5). The larger card
means considerably more KV-cache headroom than the old A6000, which is why
`--max-num-seqs` was raised from 8 → 32 on 2026-09-18 (confirmed against
vLLM's own KV-cache accounting, not guessed — see §5 comment trail).

---

## 2. Process Map

```
┌──────────────────────────────────────────────────────────────────────┐
│ RunPod Pod (single container, /workspace persistent volume, MooseFS)  │
│                                                                          │
│  vLLM engine          gateway (monolith)      MySQL/MariaDB            │
│  port 7777            port 7778               port 3306                │
│  (watchdog, added      (watchdog auto-        (watchdog auto-          │
│   2026-09-22 —          restart, ~30s)          restart loop; distro   │
│   see below)                                    mariadb.service can    │
│                                                  squat on 3306 — §2a)  │
│                                                                          │
│  OCR pool (4 procs)    Embedding service                                │
│  ports 7780-7783       port 7779                                        │
│  (watchdog per-port,   (localhost only,                                 │
│   PaddleOCR segfaults)  no watchdog loop)                                │
└──────────────────────────────────────────────────────────────────────┘
                              ▲
                     see §6 for how this reaches
                     the public internet today
```

Everything is started/supervised by `/workspace/start_all.sh` (idempotent —
checks each service's `/health` before starting, safe to re-run after a pod
restart).

### vLLM now has a watchdog (changed from the 2026-08-26 revision of this doc)

`vllm.entrypoints`'s **EngineCore** can die outright from a CUDA "illegal
memory access" inside its own fused kernels — hit twice, in two different
kernels, same symptom:
- **2026-09-21 09:02:29** — MoE shared-experts auxiliary CUDA stream
  (`shared_experts.py maybe_forward_async/wait`). Worked around by
  `VLLM_DISABLE_SHARED_EXPERTS_STREAM=1` in `vllm_start.sh` (forces the
  single-stream path, costs a little decode overlap).
- **2026-09-22 06:16:45** — GDN attention kernel. Different code path, **not**
  covered by the flag above — this class of crash can't be eliminated
  outright, only recovered from quickly.

When EngineCore dies, the APIServer process **stays alive**, keeps port 7777
open, and correctly answers `/health` with 503 — but nothing was polling that
endpoint, so the 2026-09-22 crash sat undetected for **~21 minutes** until a
human noticed. `vllm_watchdog.sh` closes that gap: polls `/health` every 15s,
kills + restarts on 2 consecutive failures, same pattern as
`gateway_watchdog.sh`. Two extra things it handles that a naive restart loop
wouldn't:
- **Adopts** an already-healthy vLLM on first start instead of restarting it
  (tracked via `logs/vllm.pid`), so installing the watchdog itself never
  causes an outage.
- Sweeps **`VLLM::` process names**, not just `vllm.entrypoints` — the
  EngineCore worker is a separate multiprocessing child that renames itself
  and doesn't match the parent's cmdline pattern. Confirmed live on
  2026-09-22: an orphaned EngineCore held the full GPU memory reservation and
  blocked every subsequent launch with "Engine core initialization failed"
  until killed by name.

The actual launch command lives in `vllm_start.sh` (not inlined in
`start_all.sh`) specifically so the one-shot boot path and the watchdog's
restart path can never drift apart.

### 2a. MySQL — new failure mode since 2026-08-26

The distro's `mariadb.service` (datadir `/var/lib/mysql`) auto-enables itself
whenever `apt-get install mariadb-server` runs (e.g. after a container reset)
and wins the race for port 3306 on every reboot. It has none of the
platform's users/database, so the gateway fails at import with
`pymysql.err.OperationalError: (1045, "Access denied for user 'avaniko'")`,
while `start_all.sh`'s respawn loop would otherwise crash-loop the *real*
server against "Address already in use" forever. `start_all.sh` now detects
this (port held but `mysql -e "SELECT 1"` fails) and fails loudly with the
fix instead of crash-looping: `sudo systemctl disable --now mariadb`.

- **OCR** — unchanged in shape (bash `while true` respawn loop per port;
  PaddleOCR can segfault) but now **4 isolated processes**, ports
  7780–7783, each pinned to `OMP/OPENBLAS/MKL/PADDLE_PDX_CPU_NUM_THREADS=2`
  (benchmarked, not assumed — 2 threads beat 1 at every concurrency level
  tested). Requires `paddlepaddle==3.0.0` exactly; 3.3.1 crashes every real
  OCR request with a PIR/oneDNN executor bug.
- **Gateway** — unchanged: `gateway_watchdog.sh` health-checks port 7778
  every 15s, kills + restarts on 2 consecutive failures. Still `--workers 1`
  (see §9 — the 2026-08-10 524 incident's recommendation to raise this was
  never applied).

---

## 3. The Gateway Is One File

`/workspace/gateway/main.py` — a single monolith, now **4,221 lines**, all
routes and business logic in one process (`uvicorn main:app --workers 1`).
`gateway/app/routers/` still exists and is still **not** wired into the
running app (dead code, unchanged open item from before).

Key endpoints are unchanged from the 2026-08-26 revision (`/v1/chat/completions`,
`/v1/extract`, `/v1/ask`, `/v1/files*`, auth, admin, `/getkey`, `/health`,
`/chat` dev UI). New since then: an **admin console "System" dashboard**
(live process/queue/GPU status tab in `gateway/static/admin_console.html`,
restyled as a HUD) and an inline onboarding flow in the chat UI replacing
native `prompt()`/`alert()` dialogs — both UI-only, no new API surface.

---

## 4. Model Serving (vLLM)

Launched via `vllm_start.sh` (shared by `start_all.sh` and `vllm_watchdog.sh`):

```
FLASHINFER_CUDA_ARCH_LIST=12.0 \
VLLM_USE_DEEP_GEMM=0 \
VLLM_DISABLE_SHARED_EXPERTS_STREAM=1 \
python -m vllm.entrypoints.openai.api_server \
  --model /workspace/models/Qwen3.6-35B-A3B-FP8 \
  --served-model-name qwen3.6-35b \
  --host 127.0.0.1 --port 7777 \
  --dtype auto \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.85 \
  --max-num-seqs 32 \
  --max-num-batched-tokens 32768 \
  --trust-remote-code \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3 \
  --kv-cache-dtype fp8_e4m3
```

| Setting | Value | Change from 2026-08-26 |
|---|---|---|
| Model checkpoint | **`Qwen3.6-35B-A3B-FP8`** | Was `-GPTQ-Int4`. Weights format changed. |
| `--max-num-seqs` | **32** | Was 8. Raised 2026-09-18 after checking vLLM's actual KV-cache accounting (~62.6x headroom at 65,536 tokens/request on the new GPU), not guessed. |
| `--max-num-batched-tokens` | **32768** | Was 4096, then found to be 16384 in prod on 2026-09-19 and diagnosed as a prefill-scheduling bottleneck (see `SLOWNESS_INVESTIGATION_2026-09-19.md`) causing 40–112s latency on large-prompt (SQL/analytics) requests; raised to 32768. |
| `--reasoning-parser qwen3` | added | New flag, not present before. |
| `VLLM_DISABLE_SHARED_EXPERTS_STREAM=1` | added | Workaround for the 2026-09-21 EngineCore crash (§2). |
| `FLASHINFER_CUDA_ARCH_LIST=12.0` | added | This GPU is Blackwell (sm_120); needs CUDA toolkit ≥12.9 on PATH and this exact arch string (not `"12.0f"`) to build FlashInfer/Triton kernels. |
| KV cache dtype | fp8_e4m3, fixed scale 1.0 | Unchanged — still not calibrated; same hybrid-Mamba limitation as before. |
| vLLM version | 0.19.1 (unverified this revision — re-check if upgraded) | |

**Known rough edge (new):** CUDA 12.6/12.8 both failed this model's
FlashInfer/Triton kernel builds outright on the new GPU
(`nvcc`/"SM 12.x requires CUDA >= 12.9"); needs CUDA 12.9+ toolchain on PATH
even though the driver reports CUDA 13.0.

---

## 5. Request Scheduling — Soft Priority Queues (now 4 classes)

Same admission-control design as before (`_VLLMScheduler` in
`gateway/main.py`, ~line 1137) — still gateway-side only, still not
preemptive, still one shared KV-cache pool. Two changes since 2026-08-26:

```python
_VLLM_TOTAL_SLOTS = 30   # vLLM launched with --max-num-seqs 32; keeps
                         # headroom outside this accounting for calls that
                         # bypass the scheduler (e.g. /health)
_VLLM_RESERVED = {"CHAT": 8, "AGENT": 4, "VISION": 8, "DOCUMENT": 8}
```

1. **Total slots raised 30** (was 7), matching the `--max-num-seqs 8→32` GPU
   upgrade above.
2. **New `VISION` class**, added 2026-09-18 after a real incident: a single
   user firing 10 concurrent image/vision-hybrid extraction calls drove
   "Running" sequences to 5 and stalled *other users'* plain-text DOCUMENT
   requests for 17–77s — heavy multimodal prefill was crowding out cheap
   text calls with no isolation between them. VISION now gets its own
   reserved ceiling so an image burst can't eat DOCUMENT's (or anyone
   else's) slots. Reservations now **sum to exactly the total** (a strict
   partition, not a soft minimum).

| Function / endpoint | Queue class |
|---|---|
| `_llm()`, `_llm_retry_truncation()`, `_llm_sse()` (text-only extraction, map-reduce, self-correct, RAG-ask) | `DOCUMENT` |
| Any extract/ask call carrying images (≤`MAX_VISION_PAGES` = 10, native-vision hybrid path) | `VISION` |
| `_vllm_post()`, `_needs_web()`, `_detect_task()`, `/chat` dev UI | `CHAT` |
| `chat_completions()` | `AGENT` if request has `tools`/`tool_choice`, else `CHAT` |
| `/files/ask` (legacy streaming path) | `DOCUMENT` |

Full changelog: `/workspace/GATEWAY_QUEUE_ISOLATION_CHANGES.md`.

---

## 6. Public Exposure — messier than 2026-08-26, now multiple layers

This pod still has **no public IP of its own** (`eth0` is a private
`/32`, `192.168.100.139`); the provider NATs a public `<ip>:<port>` onto one
internal port. Since the last revision of this doc, that internal port has
moved more than once and `start_all.sh` now runs **four separate plain-TCP
`socat` relays**, not one, because outages kept being caused by the dashboard
side changing without the pod side following:

| Relay | Status |
|---|---|
| `9999 → 7778` | **The live public path today** — provider's "Exposed Services" dashboard maps this to public `50.35.188.68:20004`. |
| `20004 → 7778` | Added 2026-09-22 after discovering the host actually NATs through 20004, not 20006. |
| `20006 → 7778` | Tried first on 2026-09-22, found **not** mapped publicly (refuses). Left running, currently dead weight. |
| `20007 → 7778` | Original relay from 2026-09-17; superseded, likely dead weight now too. |

**All of these are plain HTTP with no TLS anywhere in the path** — auth is
only the gateway's own bearer token, sent in clear over the public internet.
The provider **reassigns the public port on every pod reset**, so the
dashboard row must be re-checked after any restart — this exact failure mode
(internal port healthy, public mapping pointing at a dead port) caused two
prior outages (`1111→20007`, then `9999→20004` itself once).

**In progress, not yet live:** `DNS_MIGRATION_CHECKLIST.md` (captured
2026-09-21) — moving `avaniko.com` DNS from GoDaddy to Cloudflare so a
**Cloudflare Tunnel** can serve `llm.avaniko.com` with real TLS, replacing
the socat relays above. `api.avaniko.com` (Azure/IIS, unrelated service)
stays where it is. Current state verified this revision: `cloudflared`
binary is installed (`/usr/local/bin/cloudflared`) and `~/.cloudflared/`
exists, but **no tunnel config/credentials have been created yet** — the
"Then (on the pod, I run these)" steps in the checklist are still pending.

---

## 7. Request Flow — How Many LLM Calls Per Request

Unchanged from the 2026-08-26 revision — see
`LLM_CALL_FLOW_AND_INVOICE_ARCHITECTURE_REPORT.md` for full detail. No
server-side agentic loop; 1–3 calls per chat message; extraction is
typically 1 call, multiplying only for map-reduce/consistency/self-correction.

---

## 8. Auth / Secrets

- Same scheme as before (`x-api-key` / `Authorization: Bearer`, JWT for
  dashboard login, secrets in `/workspace/.env` and `/workspace/.s3_env`,
  both `chmod 600` and gitignored).
- **Web-search bug from `SLOWNESS_INVESTIGATION_2026-09-19.md` is now fixed
  at the dependency level** — `ddgs` (9.16.0) is installed in the gateway
  venv. Note: the `from ddgs import DDGS` import in `_web_search_sync()` is
  still *outside* the function's `try/except` (only the search call itself
  is wrapped), so this would silently reopen as an unhandled 500 if the
  dependency were ever removed again — low priority given it's installed
  now, but worth moving inside the `try` while touching that function.
- **Not fixed:** `gateway/main.py` still hardcodes
  `ADMIN_LOGIN_PASS = os.environ.get("AVANIKO_ADMIN_PASS", "Avan@123")` —
  same open item flagged in both the 2026-08-26 revision of this doc and
  `SLOWNESS_INVESTIGATION_2026-09-19.md`. Confirm the env var is actually
  set in production and remove the hardcoded fallback.
- **AWS key rotation** (`.s3_env`, flagged exposed in a chat transcript on
  2026-06-24) — status not re-verified this revision; treat as still
  pending unless confirmed otherwise.

---

## 9. Known Open Issues

| Priority | Issue | Action needed |
|---|---|---|
| 🔴 HIGH | Public exposure is plain HTTP (no TLS) with the provider silently reassigning the public port on pod reset | Finish the Cloudflare Tunnel migration in `DNS_MIGRATION_CHECKLIST.md` (binary installed, tunnel not yet configured) |
| 🔴 HIGH | Hardcoded admin password fallback (`Avan@123`) still in `gateway/main.py` | Confirm `AVANIKO_ADMIN_PASS` is set in prod; remove the fallback |
| 🟡 MED | AWS key in `.s3_env` flagged exposed 2026-06-24 | Rotate in AWS IAM console — needs a human with AWS access |
| 🟡 MED | Gateway still `--workers 1` | The 2026-08-10 524 incident and the 2026-09-19 slowness report both recommend `--workers 2+` so one stuck request can't freeze the whole service; still not applied |
| 🟡 MED | Two of the four public socat relays (20006, 20007) are likely dead weight | Verify which port the provider actually NATs today and prune the unused relays to reduce confusion |
| 🟡 MED | `gateway/app/routers/` package still dead code next to the real monolith | Wire it up or remove it |
| 🟢 LOW | `requests.jsonl` / `vllm.log` still live on the network-mounted (MooseFS) `/workspace/logs` — the root cause class of the Aug 10 outage | Gateway's own app log already moved to `/tmp`; consider moving these too |
| 🟢 LOW | `README.md` / `current.md` / `PRODUCTION_ARCHITECTURE_REVIEW.md` still describe the old two-tier layout | Should be updated or archived |

---

## 10. File Reference

```
/workspace/
├── .env                   ← gateway API_KEY, JWT_SECRET
├── .s3_env                ← AWS creds for S3 backup (chmod 600, gitignored, key needs rotation)
├── start_all.sh            ← starts/supervises everything, idempotent, run after pod restart
├── vllm_start.sh            ← single-attempt vLLM launch command (shared by start_all.sh + watchdog)
├── vllm_watchdog.sh         ← NEW — health-checks + force-restarts vLLM (added 2026-09-22)
├── gateway_watchdog.sh      ← health-checks + force-restarts the gateway
├── invoice_to_json.py       ← client-side script that calls /v1/extract
├── ocr_server.py            ← PaddleOCR service (ports 7780-7783, 4-instance pool)
├── embed_server.py          ← embedding service (port 7779)
│
├── gateway/                 ← ✅ LIVE — the real production app
│   └── main.py              ← the monolith: every route, the vLLM scheduler (4 classes), auth, everything
│
├── production/              ← ⚠️ LEGACY — old separate FastAPI app, not what's running
├── avaniko-platform/        ← ⚠️ LEGACY — old two-tier public API layer, never deployed, likely stale
│
├── models/Qwen3.6-35B-A3B-FP8/   ← model weights served by vLLM (changed from -GPTQ-Int4)
│
├── CURRENT_ARCHITECTURE.md                              ← this file
├── DNS_MIGRATION_CHECKLIST.md                            ← NEW — Cloudflare Tunnel migration plan, in progress
├── SLOWNESS_INVESTIGATION_2026-09-19.md                  ← NEW — prefill-scheduling bottleneck + ddgs bug
├── GATEWAY_QUEUE_ISOLATION_CHANGES.md                    ← priority-queue scheduler changelog
├── LLM_CALL_FLOW_AND_INVOICE_ARCHITECTURE_REPORT.md      ← full call-flow trace, chat + extract
├── EXTRACT_VISION_OCR_PIPELINE.md                        ← OCR/vision pipeline detail (dated, verify against code)
├── README.md, current.md, PRODUCTION_ARCHITECTURE_REVIEW.md, AVANIKO_FULL_REPORT.md
│                                                          ← ⚠️ STALE — describe the old two-tier layout, kept for history only
```
