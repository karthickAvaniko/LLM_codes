# KV Cache & Full vLLM/LLM Request Workflow
> Last updated: 2026-08-26 | Verified against live code + live running vLLM instance

This file explains, end to end, what the KV cache actually is, how vLLM
manages it on this deployment, and the full path a request takes from the
gateway to the model and back — for both chat and document/extraction
requests. Companion docs: `CURRENT_ARCHITECTURE.md` (overall system),
`EXTRACTION_GOLDEN_RULES.md` (extraction prompt rules).

---

## 1. What the KV cache actually is (plain explanation)

When an LLM generates text, it processes tokens one at a time, but each new
token's attention calculation needs to look back at every previous token in
the conversation. Recomputing that lookback from scratch for every single
new token would be extremely wasteful — so the model caches the intermediate
"Key" and "Value" tensors (hence **KV cache**) from every token it has
already processed, and reuses them instead of recalculating.

The KV cache is why a longer conversation/document uses more GPU memory the
further it goes — every token added to the context grows the cache. It's
also why context length and concurrent request count directly trade off
against each other: they're both drawing from the same fixed pool of GPU
memory.

---

## 2. How vLLM manages it here (PagedAttention)

vLLM doesn't give the KV cache to the model as one giant contiguous memory
block per request. It uses **PagedAttention**: the cache is split into
fixed-size "blocks" (think memory pages), and each request gets whichever
blocks it needs allocated to it dynamically, similar to how an OS manages
virtual memory pages for processes.

This is what makes the answer to "does the KV cache collide between
different requests" **no**: every request's blocks are logically private to
that request, even though they're all drawn from one shared physical pool.
A chat request and a document-extraction request running concurrently never
read or write each other's blocks.

**Prefix caching** (`--enable-prefix-caching`, on in this deployment): when
two different requests happen to start with the exact same prompt text
(e.g. the same system prompt repeated across many requests), vLLM can reuse
the already-computed KV blocks for that shared prefix instead of
recomputing them — a safe optimization, not a source of any cross-request
mixing, since it only ever reuses blocks for byte-identical input.

---

## 3. This deployment's specific KV cache config

| Setting | Value |
|---|---|
| Hardware | 1× NVIDIA RTX A6000, 49,140 MiB VRAM (no second GPU) |
| KV cache dtype | `fp8_e4m3` (changed from float16, 2026-08-26) |
| KV cache scales | Fixed at 1.0 — NOT calibrated. `--calculate-kv-scales` is deprecated in vLLM 0.19.1 and additionally auto-disabled for this specific model (hybrid Mamba/GDN layers can't run a reliable calibration pass — recurrent state is uninitialized during it) |
| Why fp8 | Halves per-token KV cache memory footprint. Freed VRAM from ~5GB to ~7.8GB free without touching model weights |
| Prefix caching | Enabled |
| Max context (`--max-model-len`) | 65,536 tokens |
| Max concurrent sequences (`--max-num-seqs`) | 8 (vLLM's own limit) |
| Model weights per instance | 21.06 GiB (measured at load time) |
| Number of engine instances | **1** — one shared KV cache pool for the entire platform. There is no hardware isolation between request types (see §5). |

Getting fp8 running required two fixes, documented here since they're not
obvious from the flag alone:
1. Needs `ninja` on `PATH` for a one-time JIT-compiled kernel (flashinfer
   batch-prefill module) — symlinked `/workspace/venv/bin/ninja` →
   `/usr/local/bin/ninja`.
2. This model's hybrid Mamba/attention layers force a KV block size of 2096
   under fp8 ("Mamba cache align mode"), incompatible with the scheduler's
   default `max_num_batched_tokens=2048` — raised to `4096` in `start_all.sh`.

---

## 4. Full request workflow — chat message

```
1. Client → gateway (port 7778)
   POST /v1/chat/completions  or  /chat  (UI)

2. Gateway builds the message list:
   - /chat (UI): IDENTITY_PROMPT + current date/time + conversation history
   - /v1/chat/completions: whatever the client sent, OpenAI-format

3. (Optional) classifier calls — cheap, queue class CHAT:
   - _detect_task()  → picks temperature/thinking preset (skipped for
     inline-image chat, forced straight to extraction mode instead)
   - _needs_web()    → decides whether to inject live web-search context

4. Gateway acquires a scheduler slot:
   await _vllm_sched.slot("CHAT")     # or "AGENT" if request has tools
   - CHAT has 2 reserved slots (of 7 total), AGENT has 1 — always
     available even if DOCUMENT traffic is saturating the rest.

5. Gateway → vLLM (localhost:7777)
   POST /v1/chat/completions
   vLLM allocates KV cache blocks for this request from the shared pool,
   runs the forward pass token by token, streams tokens back.

6. Gateway releases the scheduler slot, streams tokens to the client.

Typical LLM call count for ONE chat message: 1-3
  (1 answer call, + up to 2 cheap classifier calls)
```

---

## 5. Full request workflow — document/invoice extraction

```
1. Client → gateway (port 7778)
   POST /v1/extract  (API)   or   POST /files/ask  (UI file attach)

2. Gateway reads the uploaded file(s), runs OCR/text extraction
   (extract_pages() — native PDF text, OCR fallback via the PaddleOCR
   service on port 7780) and optionally extracts page images for the
   vision-hybrid path.

3. Gateway builds messages via _doc_messages() or _vision_doc_messages():
   system = DOC_SYSTEM + EXTRACTION_RULES  (since the question implies JSON)
   — see EXTRACTION_GOLDEN_RULES.md for the full rule set.

4. Size decision:
   - Fits in one call (SINGLE_SHOT_CHARS)  → single LLM call
   - Too large                             → map-reduce:
       _map_chunks() — N parallel chunk calls (own scheduler slots)
       _reduce_messages() — 1+ combine call(s), hierarchical if still
       too large after the first reduce

5. Gateway acquires scheduler slot(s) per call:
   await _vllm_sched.slot("DOCUMENT")
   - DOCUMENT has 0 reserved slots — uses only what CHAT/AGENT
     aren't currently using, so a burst of extraction jobs can never
     starve chat/agent latency.

6. Gateway → vLLM (localhost:7777) — same shared KV cache pool as chat,
   same model, same engine. Each of these calls gets its own private KV
   cache blocks, same as any chat request.

7. Deterministic validation: validate_extraction() checks the parsed JSON
   against the source text (field-level sanity checks, arithmetic
   cross-checks, missing-invoice-number detection, etc.).

8. If validation fails: _self_correct() — one more LLM call (queue class
   DOCUMENT) with the specific issues listed, then a final re-check.

9. Cache check/write (added 2026-08-26): a hash of the file bytes +
   question + params is checked BEFORE step 2 even starts — on a cache
   hit, everything above is skipped entirely and the previous validated
   result is returned immediately. On a cache miss, the final validated
   result is written to the cache (MySQL table extraction_cache) after
   step 8.

Typical LLM call count for ONE document (cache miss): usually 1
  (single-pass or vision-hybrid). Multiplies under map-reduce (chunks +
  reduces), consistency=N voting (+N-1 cheap calls), or a self-correction
  retry (+1). Cache hit: 0 LLM calls.
```

---

## 6. The scheduler — how "CHAT gets priority" actually works

`_VLLMScheduler` in `gateway/main.py` (~line 826) sits in front of every
single outgoing call to vLLM, regardless of which workflow above triggered
it:

```python
_VLLM_TOTAL_SLOTS = 7    # vLLM's own limit is 8; 1 slot kept as headroom
_VLLM_RESERVED = {"CHAT": 2, "AGENT": 1, "DOCUMENT": 0}
```

- A request can always enter its own reserved minimum, even if every other
  slot is full.
- Beyond its own reservation, a class can use any slot that isn't currently
  needed to fill another class's unmet reservation.
- **Not preemptive** — once a request is admitted and generating, it can't
  be interrupted from outside vLLM. This only controls admission of *new*
  requests, not what happens to ones already running.
- This is purely a queueing/fairness mechanism. It has zero effect on the
  KV cache itself — every admitted request, regardless of class, draws from
  the exact same shared pool described in §2.

---

## 7. Summary — what's isolated, what isn't

| | Isolated? | How |
|---|---|---|
| One request's KV cache blocks vs another's | ✅ Yes | PagedAttention allocates private blocks per request automatically — always true, regardless of concurrency or request type |
| Chat vs Document vs Agent — which gets the next available concurrency slot | ✅ Yes (soft) | `_VLLMScheduler` reserved-minimum admission control |
| Chat vs Document vs Agent — GPU memory pool / KV cache capacity | ❌ No | One engine, one shared pool, one GPU — no hardware separation. Would require a 2nd GPU (real isolation, real cost) or 2 vLLM processes on this 1 GPU (technically possible but each needs its own ~21GB weight copy, leaving very little room for KV cache in either — capacity trade-off judged not worth it, decision made 2026-08-26 to stay on the shared single-engine setup) |
