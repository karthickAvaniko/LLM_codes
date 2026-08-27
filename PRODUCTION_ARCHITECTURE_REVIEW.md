# Production Architecture Review — Avaniko AI Gateway

**Status:** Planning document only — no code was changed while producing this report.
**Scope:** Why the gateway keeps needing watchdog restarts, and the structural risks behind it.
**Evidence base:** `/tmp/gateway_watchdog.log`, `/tmp/gateway.log` (51,952 lines), `/workspace/logs/vllm.log`,
`gateway/main.py` (3,260 lines), `start_all.sh`, `gateway_watchdog.sh`, `INCIDENT_2026-08-10_524_ERROR.md`.

---

## 1. Executive Summary

| # | Finding | Risk | Confidence |
|---|---|---|---|
| 1 | **The app's own logging goes to the network volume, unwrapped, from 55 call sites across the codebase.** This is almost certainly why gateway hangs are still happening after the earlier `_append_jsonl` fix — that fix covered custom JSONL logs, not Python's own `logging` module, which every part of the app calls directly and synchronously. | **Critical** | High — confirmed by code inspection |
| 2 | **Single uvicorn worker (`--workers 1`) is still the architecture.** Any one blocked call anywhere freezes the entire service for every concurrent user. This was flagged in the 2026-08-10 incident report and never implemented. | **Critical** | High — confirmed, unchanged since Aug 10 |
| 3 | **A bug introduced by this session's own truncation-retry fix can request more output tokens than fit in the remaining context**, causing repeated hard failures (`VLLMValidationError`) instead of a clean retry. Confirmed live in `vllm.log` on 2026-08-20. | Medium | High — confirmed in logs |
| 4 | **No graceful degradation when vLLM is restarted/unavailable** — confirmed cascade of `500` errors to real users during a ~7-minute window on 2026-08-20 while vLLM was down. | Medium | High — confirmed in logs |
| 5 | MariaDB's datadir sits on the same flaky network volume as everything else, with no evidence it has ever hung (only crashed once, per the Aug 10 incident) — but a stall, as opposed to a crash, would **not** be caught by its restart loop. | Medium | Medium — inferred, not yet observed |

None of the concrete bugs behind findings 1 and 3 were previously known — both were found by reading the code and logs for this review, not reported by the user.

---

## 2. Root Cause of the Ongoing "Unresponsive" Gateway Restarts

`/tmp/gateway_watchdog.log` shows the watchdog force-killing and restarting the gateway at least 7 times between 2026-08-18 and 2026-08-20 (e.g. `04:16:41`, `10:31:27`, `12:12:16`, `12:36:59`, `12:42:04`, `16:14:36`, `16:49:07`). Every one of these is preceded by `health check failed`, not by a crash — the process stops responding to *everything*, including its own `/health`, and is only recovered by `kill -9` (per `gateway_watchdog.sh`'s comment, this is the same D-state-on-network-I/O symptom root-caused in the 2026-08-10 incident report).

Cross-checking `/tmp/gateway.log` (51,952 lines spanning this window) for tracebacks found only **two** exception clusters — at 2026-08-18 09:22 (a client disconnecting mid-upload, harmless) and 2026-08-20 11:32 (`httpx.ConnectError: All connection attempts failed` to vLLM, because vLLM was itself mid-restart — see §4). **Neither correlates with any of the 7 watchdog-restart timestamps.** This is an important negative result: it confirms the hangs are silent freezes with zero log output, not visible crashes — exactly the fingerprint of a blocking synchronous call stalling the single event loop thread, not an unhandled exception.

The 2026-08-10 incident already fixed the most obvious instance of this (`_append_jsonl`, the app's custom JSONL request logger, now wrapped in `run_in_executor` via `_log_async`). **But that fix did not cover every synchronous write to the network volume.** Reading `gateway/main.py` lines 24–33:

```python
LOG_DIR = Path("/workspace/logs")          # <-- network-mounted volume
...
_fh = RotatingFileHandler(LOG_DIR / "gateway_app.log", maxBytes=50_000_000, backupCount=5)
_fh.setFormatter(...)
logging.getLogger().addHandler(_fh)        # <-- attached to the ROOT logger
```

Python's standard `logging` module is **not async** — every `logger.emit()` call does a blocking `write()` + `flush()` on whatever thread calls it. This handler is attached to the *root* logger, so it fires on every one of the **55 `log.info` / `log.warning` / `log.error` call sites** across the file — including calls made directly inside `async def` request handlers (e.g. line 868's `log.warning(...)` inside `_llm_retry_truncation`, or the `CHAT | auto task: ...` lines visible throughout `gateway.log`). None of these 55 call sites are wrapped in `run_in_executor`. Every one of them is a potential stall point: if the network volume hiccups for even a few seconds while any request anywhere is mid-`log.info()`, the single asyncio event loop — the only thread handling every concurrent request, including `/health` — blocks with it.

This is the same class of bug the Aug 10 incident already fixed once, reappearing through a second, unaddressed code path. It is the most likely explanation for why hangs are still happening at roughly the same frequency after the earlier fix.

---

## 3. Single-Worker Architecture Risk

`gateway/start.sh` runs `uvicorn main:app --workers 1`. With one worker, there is exactly one Python process and one event loop serving every user. The blast radius of *any* stall — network volume, a slow downstream call, anything — is 100% of concurrent traffic, for the full duration of the stall, until the watchdog notices (up to 30s: two 15s-spaced failed checks) and force-restarts (3–5s). This matches the recommendation already made in the Aug 10 incident report and never acted on.

**Why it hasn't been trivially bumped to `--workers 2+` yet — and what's actually needed first:**
Rate limiting and API-key state are held in **in-process Python dicts** (`_rpm_windows`, `_daily_counts`, and the in-memory `API_KEYS` cache backed by MySQL). With multiple workers, each is a separate process with its own memory — rate limits would be enforced *per worker*, not globally (a client could get up to N× their configured limit by landing on N different workers), and an API key created/revoked in one worker wouldn't be visible in another until the next MySQL-backed cache refresh. This isn't a reason not to go multi-worker, but it means multi-worker isn't a drop-in flag flip — the rate-limit counters need to move to a shared store (MySQL, or Redis if one gets added) first, or the risk needs to be explicitly accepted as acceptable for this traffic volume.

---

## 4. No Backend-Restart Graceful Degradation

`vllm.log` shows vLLM's `EngineCore` restarting at `2026-08-20 11:39:17` (new PID `532201`). `gateway.log` shows a cascade of `httpx.ConnectError: All connection attempts failed` starting at `11:32:08` — i.e. for up to ~7 minutes, every `/v1/chat/completions` request hit an **unhandled 500** (`main.py:2931`, `_vllm_post`) instead of a clean, expected "model restarting, retry in a moment" response. This window lines up with this session's own approved `--max-num-seqs 8→16` change, which required a vLLM restart — so this specific instance was a planned maintenance window, but the gateway has no code path that distinguishes "backend intentionally restarting" from "backend genuinely broken," and a user hitting the API during ANY future vLLM restart (planned or crash) gets the same raw 500s.

**Separately, and more concerning:** the exact same `vllm.log` shows a second, live bug, unrelated to the restart —

```
vllm.exceptions.VLLMValidationError: This model's maximum context length is 32768 tokens.
However, you requested 30000 output tokens and your prompt contains at least 2769 input tokens,
for a total of at least 32769 tokens.
```

This traces directly to this session's own truncation-retry fix, `_llm_retry_truncation()` (`main.py:850`):

```python
tiers = sorted(set(t for t in (max_tokens, retry_max_tokens, 30000) if t >= max_tokens))
```

The tiers are **fixed values** (8192 / 24000 / 30000) regardless of how large the prompt already is. If `prompt_tokens + requested_max_tokens` exceeds 32,768, vLLM rejects the request outright — the retry doesn't recover, it just fails a different way, and (per the log) can repeat several times in a row on the same request pattern. **Fix direction (not yet implemented): cap each tier at `min(tier, CONTEXT_TOKENS - estimated_prompt_tokens - margin)`** rather than using flat numbers — the same style of budget already computed elsewhere in the file (`main.py:2556-2563`, `CONTEXT_TOKENS`/`CTX_MARGIN`).

---

## 5. Other Findings Checked and Ruled Out (for completeness)

- **OCR calls do not block the event loop.** `ocr_image()` (`main.py:461`) uses the *synchronous* `httpx.post(...)`, and at first read looks like a candidate for the same freeze bug — but every call site (`extract_pages`, `extract_page_images`, and the direct `ocr_image` call in the chat-image path) is correctly wrapped in `run_in_executor` (confirmed at `main.py:1610, 2409, 2422, 2623, 3135, 3164`). This is fine as-is. Minor secondary note: all of these share Python's *default* thread-pool executor along with every DB/session call in the app — a burst of many concurrent OCR calls (each with a 120s timeout) could starve unrelated fast calls (login, key lookup) of a free thread. Not urgent, but worth a dedicated executor with a bounded size if OCR volume grows.
- **No direct synchronous `requests.*` calls or unwrapped `mysql.connector`/`pymysql.connect()` calls** were found outside the already-fixed `_sync` wrapper pattern.
- **`/health` itself is clean** — it's a pure `async def` that only awaits an `httpx.AsyncClient` call to vLLM; it doesn't touch the network volume or the logging handler directly. This confirms that when the gateway hangs, the cause is a *different* concurrent request's blocking call starving the single event loop, not a problem in the health check itself.
- **Rate limiting vs. concurrency**: `--max-num-seqs 16` is in place (approved and confirmed this session). This is a good match for the previously-diagnosed page-splitting × consistency=3 concurrency problem (`ISSUE_CONCURRENT_REQUESTS_TIMEOUT.md`), though that issue's actual fix is still the client-side calling pattern, not server capacity alone.
- **Disk space is not a contributing factor**: the network volume is at 83% (135TB free of 756TB) — the 17.5GB `avaniko-project.zip` sitting in `/workspace` is not a capacity risk, just orphaned clutter worth deleting at some point.

---

## 6. DB Layer Risk (MariaDB on the Network Volume)

`start_all.sh` runs `mariadbd` with `--datadir=/workspace/mysql` — the same MooseFS-backed volume implicated in every I/O-stall finding above — inside a `while true` respawn loop. That loop only restarts `mariadbd` if the **process exits**. The 2026-08-10 incident describes a crash (core dump), which this loop now correctly catches (it did not exist before that incident). But a **stall** — the DB process staying alive while blocked on a slow I/O syscall, the same failure mode already observed twice in the gateway itself — would not exit, and so would not trigger a restart; it would just make every DB-dependent request (auth, key lookups) hang until the underlying I/O resolves. There is currently no timeout-based health check for MySQL analogous to the gateway's watchdog. Given the gateway's own DB calls already go through `run_in_executor` (per this session's earlier fix), a stalled DB wouldn't freeze the *whole* gateway the way a stalled log write would — but it would still hang every request that happens to need DB access (login, key validation) for as long as the stall lasts.

---

## 7. Prioritized Fix List (not implemented — for decision)

1. **Route the root-logger `RotatingFileHandler` off the network volume, or wrap every emit in the same async pattern as `_log_async`.** Highest priority — this is the most likely still-live cause of the repeated "unresponsive" restarts, and the fix is small: either point `_fh` at a local `/tmp` path (mirroring what `gateway_watchdog.sh` already does for its own logs, and what `_log_async` already does for JSONL logs) or add a `QueueHandler`/`QueueListener` so log emission never blocks the calling coroutine. Lowest effort, highest expected impact.
2. **Cap the truncation-retry tiers by remaining context budget**, not fixed numbers — closes the confirmed `VLLMValidationError` failure mode in §4. Small, isolated code change.
3. **Add a backend-unavailable response path** — when `_vllm_post` gets a connection error, return a clean `503` with a short retry hint instead of an unhandled `500` traceback, at minimum for the duration of a known/detected restart. Moderate effort, meaningfully better user-facing behavior during any future maintenance window.
4. **Move rate-limit/API-key state to a shared store (MySQL row-level counters, or add Redis), then move to `--workers 2+`.** This is the structural fix for the single-point-of-failure blast radius described in §3 — but sequence matters: multi-worker before shared state would silently break rate limiting. Higher effort, but the highest ceiling on the "any user's stuck request takes down everyone" risk.
5. **Add a stall-aware health check for MariaDB** (a query with a short timeout, on the same cadence as the gateway's watchdog) so a stuck-not-crashed DB is caught the same way. Moderate effort, closes a real but currently unobserved gap.
6. **Give the OCR-related executor calls a dedicated, bounded thread pool** separate from DB/session calls, so a burst of slow OCR work can't starve fast auth/key lookups of a thread. Low urgency; revisit if OCR volume grows.
7. Housekeeping: delete or move `avaniko-project.zip` (17.5GB, orphaned) out of `/workspace`; not a current risk, but no reason to leave it on the shared volume either.
