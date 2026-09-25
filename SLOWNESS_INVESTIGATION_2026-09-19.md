# LLM Slowness Investigation — 2026-09-19

**Reported by:** Yalini Natarajan
**Investigated by:** Claude Code (live system check, no code changes made)
**Scope:** "The LLM is very slow" — checked live GPU/vLLM/gateway state, request logs, and prior incident docs.

---

## TL;DR

The GPU and the vLLM model server are **healthy and mostly idle** — this is not a capacity or hardware problem. The slowness is real and shows up as a handful of individual requests taking **40–112 seconds** to answer, even though the model itself only generated 30–70 tokens for them. The most likely cause, based on live evidence, is a **prefill scheduling bottleneck**: vLLM is launched with `--max-num-batched-tokens 16384`, but the SQL/analytics chat workload regularly sends prompts of 5,000–17,000+ tokens (schema context, table indexes). A prompt near or above that 16,384 budget has to be chunked across many scheduler steps instead of processed in one pass, which drags out wall-clock time badly even with zero other traffic competing for the GPU.

A second, unrelated but real bug: the web-search feature (`ddgs` package) is **not installed** in the gateway's venv, so any query the model classifies as needing live web data throws an unhandled exception (3 of the last ~2,856 chat calls in 24h; 8 total in the last 2 days). Low frequency, but worth a one-line fix.

---

## 1. What's NOT the problem

- **GPU**: RTX PRO 6000, 0% utilization at check time, 86/97 GB VRAM used (expected — model weights + reserved KV cache at `--gpu-memory-utilization 0.85`). No thermal or power issues.
- **vLLM engine**: `Running: 0 reqs, Waiting: 0 reqs` for nearly the entire monitoring window. Prefix cache hit rate ~37%, no errors in the live log, no OOM, no crash. Throughput is fine when it's actually generating (>100 tok/s in several samples).
- **Not a queueing pileup**: the gateway's admission-control scheduler (`_VLLMScheduler` in `gateway/main.py`) was already correctly resized on 2026-09-18 to `_VLLM_TOTAL_SLOTS = 30` with per-class reservations (CHAT 8 / AGENT 4 / VISION 8 / DOCUMENT 8), matching vLLM's `--max-num-seqs 32`. This is not under-provisioned.

## 2. What the evidence shows

Pulled `ms` (round-trip time) and token usage for every chat request in the last 2 hours from `/workspace/logs/requests.jsonl` (37 requests):

| Metric | Value |
|---|---|
| p50 latency | 741 ms |
| p95 latency | 43,722 ms |
| max latency | 111,567 ms |
| avg generation throughput (when running) | ~112 tok/s |

The three slowest requests, all from the same client IP, in sequence:

| Time | Latency | Prompt tokens | Completion tokens |
|---|---|---|---|
| 07:28:38 | 76.4 s | 5,642 | 36 |
| 07:29:29 | 43.7 s | 5,651 | 43 |
| 07:31:24 | **111.6 s** | **16,771** | 70 |

None of these have any reasoning/thinking tokens (`reasoning_tokens: 0`) — the time isn't going into hidden chain-of-thought. A 70-token answer simply should not take 111 seconds on an idle GPU.

Cross-checking the gateway's own app log (`/tmp/avaniko_gateway_logs/gateway_app.log`) for the 111-second request: the gateway logged the task classification at `07:29:33`, then logged **nothing else** — not even a web-search or retry line — until the underlying vLLM call completed at `07:31:24`. Health-check pings kept firing on schedule every 15s the whole time, which rules out the gateway event loop being frozen (the Aug 10 524 incident's failure mode). The delay is inside that one call to vLLM itself.

The pattern that lines up with every piece of evidence: the 16,771-token prompt sits right at (and the two others are well within striking distance of) vLLM's `--max-num-batched-tokens 16384` ceiling (set in `start_all.sh`). When a single prompt is that large relative to the per-step token budget, vLLM has to process it in multiple chunked-prefill steps rather than one pass — which explains the near-idle `Running`/`Waiting` counters (it's not "waiting in a queue," it's grinding through its own oversized prompt in small chunks) and the very low decode throughput briefly observed (0.9–1.4 tok/s at 07:30:47–07:31:07, consistent with mostly-prefill activity, not generation).

**Likely root cause:** `--max-num-batched-tokens 16384` is too tight for this workload's typical prompt sizes (the text-to-SQL / analytics chat path routinely sends multi-KB table-schema context).

## 3. Recommended fix (not yet applied — needs your go-ahead, this is live prod)

- Raise `--max-num-batched-tokens` in `start_all.sh` (currently 16384) — e.g. to 32768, well below `--max-model-len 65536`. This mainly affects prefill scheduling, not KV cache reservation, so the VRAM impact should be small, but headroom is already tight (86/97 GB used) — test on a low-traffic window and watch `nvidia-smi` after restart.
- Restart vLLM to apply (`gateway_watchdog.sh` / `start_all.sh`), then re-run the same latency check on `requests.jsonl` to confirm the p95/max drop.

## 4. Separate bug found: web search is broken

`gateway/main.py`'s `_web_search_sync()` does `from ddgs import DDGS` with no dependency installed in `/workspace/gateway/venv`. Confirmed via `pip show` — package genuinely absent. When the model's own auto-classifier (`_needs_web`) decides a question needs live web data, this throws an **unhandled `ModuleNotFoundError`**, which isn't caught (the `try/except` in that function only wraps the search call, not the import), producing a 500 to the client.

- Frequency: 3 of ~2,856 chat/completions calls returned 500 in the last 24h; 8 occurrences total across the last 2 days, all tied to this same error.
- Fix: `pip install ddgs` in the gateway venv (or `duckduckgo-search` if pinning the older package name), or move the import inside the existing `try` block so a missing dependency degrades to "no web context" instead of a 500.

## 5. Housekeeping noticed along the way (not blocking)

- Gateway still runs `--workers 1`, which the 2026-08-10 524-error incident report explicitly recommended raising to 2+ so one stuck request can't freeze the whole service. That recommendation was never applied.
- `/workspace/logs` is on the network-mounted (MooseFS) volume, which was the root cause of the Aug 10 outage; the gateway's own app log was already moved off it (`/tmp/avaniko_gateway_logs/`), which is good, but `requests.jsonl`/`vllm.log` are still on the network mount.
- OCR pool (ports 7780–7783) had a burst of `500 Internal Server Error` on all four instances on 2026-09-17 ~09:49–09:51; self-recovered via the watchdog restart loop and hasn't recurred since — no action needed unless it comes back.

---

## ⚠️ Security items found during this check (unrelated to the slowness, flagging separately)

1. **A plaintext GitHub personal access token is sitting in `~/.bash_history`** (from a `git push` command). Recommend revoking/rotating it on GitHub regardless of whether it was ever misused.
2. **`current.md` in this repo contains a live-looking production API key** (`sk-ava-...`) in a curl example. If this file is pushed to a remote (public or shared) repo, that key is exposed — recommend rotating it and replacing the example with a placeholder.
3. **`gateway/main.py` has a hardcoded default admin password** (`AVANIKO_ADMIN_PASS` falls back to `"Avan@123"` if the env var isn't set) committed to source. Recommend confirming the env var is actually set in production and removing the hardcoded fallback.

I did not rotate/revoke anything — flagging for you to action.
