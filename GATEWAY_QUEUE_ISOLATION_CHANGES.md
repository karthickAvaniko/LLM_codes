# Gateway Queue Isolation — Changes

> Soft priority isolation (DOCUMENT / CHAT / AGENT) added to `/workspace/gateway/main.py`. NOT applied/restarted on the live process (port 7778) — code only, pending go-ahead. `python3 -m py_compile main.py` passes.

## Why

Single RTX A6000 (49GB VRAM), one vLLM engine (`Qwen3.6-35B-A3B-GPTQ-Int4`, `--max-num-seqs 8`), one shared KV cache pool. A second full model instance doesn't fit (one instance already uses ~43GB), so true per-queue KV cache partitioning isn't possible on this hardware. Instead: gateway-side admission control so DOCUMENT jobs (map-reduce chunk calls, consistency votes) can't occupy every vLLM concurrency slot and add latency to interactive CHAT/AGENT traffic.

## What was added

`_VLLMScheduler` class + module constants, inserted before `_llm()` (~line 825 pre-edit):

- `_VLLM_TOTAL_SLOTS = 7` — vLLM runs `--max-num-seqs 8`; gateway caps itself at 7, leaving 1 slot of headroom for calls outside this accounting (e.g. `/health`).
- `_VLLM_RESERVED = {"CHAT": 2, "AGENT": 1, "DOCUMENT": 0}` — always-available minimum per class. DOCUMENT gets no reservation (it's the batch/background workload); CHAT gets the largest reservation since it's the most latency-sensitive, interactive path; AGENT gets 1 so an in-progress tool-calling loop isn't starved either.
- `_vllm_sched = _VLLMScheduler(...)` — module-level singleton. `async with _vllm_sched.slot(queue_class): ...` wraps every outgoing call.
- Admission rule: a class can always take its own unused reserved slots; beyond that, it can take shared/unreserved capacity only if doing so wouldn't stop another class from reaching its own reserved minimum. Not preemptive — an in-flight vLLM generation can't be interrupted from outside; this only gates admission of new requests.

## Call sites wired (every direct call to `VLLM_URL` in the file — 8 total)

| Site | Function | Class | Notes |
|---|---|---|---|
| `_llm()` | shared helper | `queue_class` param, default `DOCUMENT` | extraction, map/reduce, self-correct, RAG-ask all use default |
| `_llm_retry_truncation()` | shared helper | `queue_class` param, default `DOCUMENT`, threaded into its internal `_llm()` call | same callers as above |
| `_llm_sse()` | shared helper | `queue_class` param, default `DOCUMENT` | used by `/v1/files/{id}/ask` streaming, RAG-ask streaming |
| `_vllm_post()` | shared helper | `queue_class` param, default `CHAT` | used by `chat_completions()` non-streaming path |
| `_needs_web()` | inline classifier | hardcoded `CHAT` | only called from chat paths |
| `_detect_task()` | inline classifier | hardcoded `CHAT` | only called from chat paths (skipped in agent-passthrough mode) |
| `chat_completions()` `event_stream()` | inline streaming | `_qclass = "AGENT" if _agent else "CHAT"` | `_agent` = client sent `tools`/`tool_choice` |
| `chat_completions()` non-streaming | via `_vllm_post(c, body, queue_class=_qclass)` | same `_qclass` | |
| `/chat` (HTML UI) `stream()` | inline streaming | hardcoded `CHAT` | UI has no tool-calling mode |
| `/files/ask` legacy non-JSON streaming branch | inline streaming | hardcoded `DOCUMENT` | JSON branch reuses `_llm_retry_truncation` (already `DOCUMENT` by default) |

All DOCUMENT-pipeline call sites inside `answer_document()`, `_self_correct()`, `_extract_critical_fields()`, and the `/files/ask` JSON-extraction branch needed **no changes** — they already call `_llm`/`_llm_retry_truncation` with no explicit `queue_class`, which defaults to `DOCUMENT`.

## Not changed

- Request/response payloads, retry/timeout logic, streaming behavior, and error handling are untouched — the scheduler is a transparent wrapper.
- vLLM launch flags, KV cache config, `--max-num-seqs` — unchanged.
- No restart performed.

## To activate

Restart the gateway process (`pkill -f "uvicorn main:app"`, then `gateway_watchdog.sh` will bring it back up, or run `start_all.sh`) — requires user go-ahead, this is a live production service.
