# Invoice-to-JSON Pipeline — Accuracy, GPU, and Optimization Report

**Status:** Planning document only — no changes implemented. Written to answer three
questions: (1) current measured accuracy, (2) what a more powerful GPU would/wouldn't
change, (3) what can still be improved on the current GPU + model, without upgrading either.

All numbers below are pulled directly from `/workspace/logs/requests.jsonl` (real request
history from this session's testing), not estimates.

---

## 1. Current hardware & model setup

| Component | Value |
|---|---|
| GPU | 1× NVIDIA RTX A6000, 48 GB VRAM (Ampere, compute capability 8.6) |
| GPU memory in use | ~41.6 GB (85% utilization cap set in launch config) |
| Host CPU / RAM | 96 cores / 503 GB RAM (not a bottleneck — GPU is) |
| Model | Qwen3.6-35B-A3B, GPTQ **4-bit quantized** (23 GB on disk) — MoE architecture, ~3B active params per token |
| Context window | 32,768 tokens (`--max-model-len 32768`) |
| Max concurrent sequences | 8 (`--max-num-seqs 8`) |
| Precision | float16 compute, int4 weights |

This is a **single mid-tier workstation GPU** running a **quantized** medium-size MoE model —
not a datacenter-class setup (A100/H100) and not running the model at full precision.

---

## 2. Measured accuracy (last 100 real `/v1/extract` calls)

| Metric | Value |
|---|---|
| Calls with a hard error (crash/exception) | 0% |
| `validation.ok: true` (passed all deterministic checks) | **81%** |
| `validation.ok: false` (flagged issue survived self-correction) | **19%** |

**Breakdown of the 19% that still fail validation, by issue type:**

| Issue | Count (of 100) | What it means |
|---|---|---|
| `total_mismatch` | 12 | line items don't sum to stated subtotal, or subtotal+tax ≠ total |
| `invoice_number_missing` | 5 | a labeled invoice number wasn't found anywhere in the output |
| `subtotal_as_line_item` | 2 | subtotal duplicated as a fake line item |
| `not_json` | 1 | model didn't return parseable JSON even after correction |

Note: `validation.ok: false` does **not** mean the output is unusable — it means our own
deterministic checks caught something and self-correction didn't fully resolve it, so the
caller is told to review it. Most of these are borderline arithmetic/consistency issues, not
wholesale hallucination.

**Caveat on the 81% figure:** this sample mixes real extraction traffic with several fixes
landing *during* the same session — the 81% is a lower bound for where things stand right now,
not a fully independent, post-all-fixes measurement. See §5 (regression suite) for how to get
a trustworthy number going forward.

---

## 3. Measured throughput / latency (same 100-call sample)

| Metric | Value |
|---|---|
| Average latency | 26.0 s |
| p50 (median) | 17.1 s |
| p90 | 57.5 s |
| Dominant strategy in this sample | `vision_hybrid+consistency3` (79/100) — i.e. 3 full LLM passes per document, then merged |

Consistency-voting (`consistency=3`) directly multiplies latency by roughly 3x versus a
single pass, in exchange for the majority-vote noise reduction. This is the main lever
already in your hands (see §4).

---

## 4. What a more powerful GPU would change — and what it would NOT

### What it would likely improve
- **Run the model at higher precision** (int8 or fp16 instead of int4 GPTQ). Quantization to
  4-bit trades some accuracy for VRAM/speed — mainly affecting anything requiring precise
  numeric/character discrimination, which is exactly the failure mode behind
  `total_mismatch` and OCR digit-confusion. A GPU with more VRAM (e.g. 80 GB A100/H100)
  removes the *need* to quantize this hard, which should measurably reduce that error class.
- **Larger context window headroom.** More VRAM → more KV-cache room → could safely raise
  `--max-model-len` well past 32,768. This directly removes the vision+text context-overflow
  edge case we patched around (documents that need both a lot of text and several page
  images no longer risk falling back to text-only mode).
- **More concurrent sequences** (`--max-num-seqs`) → better throughput under real production
  load (multiple users/documents at once), and less GPU-batching contention — which may
  slightly reduce (not eliminate) the run-to-run non-determinism we've observed at
  `temperature=0`.
- **Cheaper `consistency=3/5`.** If per-call latency drops, running more self-consistency
  samples becomes affordable within the same wall-clock budget — directly improving accuracy
  via the exact voting mechanism already built.

### What it would NOT fix by itself
- **Prompt/logic bugs.** Every concrete bug found and fixed this session (line-item
  contamination, wrong invoice number vs PO/reference number, date confusion, currency
  gaps, vote-merge Frankenstein-merging) was a **software/prompt problem**, not a raw
  model-capability problem — a bigger GPU running the same model+prompts would reproduce the
  same classes of bugs unless the software fixes are also in place.
- **Continuous-batching non-determinism.** This is an inference-engine characteristic
  (floating-point operation ordering depends on what else is batched together), not
  something that goes away just because the hardware is faster — it may improve modestly
  from *less queuing*, but it is not eliminated by raw compute power.
- **Document-layout ambiguity.** Cases where the source document itself has two unlabeled,
  visually ambiguous dates/numbers next to each other are a data problem, not a compute
  problem — no GPU upgrade resolves genuine source-document ambiguity.

### Bottom line on hardware
A GPU upgrade (e.g. to an A100/H100 80GB) is a reasonable investment **specifically for**:
removing the quantization-accuracy tradeoff, removing the context-window ceiling, and making
higher `consistency` values cheap enough to run by default. It is not a substitute for the
software-level fixes already in progress, and several of this session's worst bugs would
still exist on better hardware without them.

---

## 5. Optimizations available on the CURRENT GPU + model (no upgrade needed)

Ordered by estimated impact-to-effort ratio:

1. **Raise default `consistency` for production traffic** (e.g. 3 → 5, within
   `MAX_CONSISTENCY_SAMPLES = 5`). Already-built, already-fixed merge logic. Direct,
   proportional accuracy gain at a direct, proportional latency/cost cost. Cheapest lever
   available right now — no code change, just a calling-convention decision.

2. **Build a golden regression test set** (10–20 fixed sample invoices spanning the document
   types seen so far — tool invoices, repair-shop receipts, bundled email+invoice packets,
   multi-address documents). Every future prompt/rule change gets run against this set before
   deploying. This is a process change, not code — but it is the single highest-leverage
   thing missing right now, since every fix this session was verified ad hoc, one document at
   a time, and at least one fix (the rigid section-layout rule) had to be reverted after
   causing a regression that ad hoc testing didn't initially catch.

3. **OCR layout/table-structure preservation** (bounding boxes + detected table structure,
   discussed earlier — PaddleOCR already computes this, the current code discards it). Would
   give the model (and our own deterministic checks) a structural signal for "these rows are
   the line-item table" instead of relying entirely on prompt instructions + vision judgment.
   Directly targets the `total_mismatch` / line-item-boundary bug family, which is the single
   largest remaining hard-issue category (12 of 19 failures in the sample above).

4. **Add more field-presence deterministic checks**, following the same pattern as
   `vendor_missing` / `invoice_number_missing` / `buyer_missing` / `due_date_missing`
   (already added this session) — extend to remaining high-value fields as new failure
   patterns are found. Cheap, safe, incremental.

5. **Second self-correction round** (currently capped at exactly one corrective pass). A
   bounded second attempt when the first correction doesn't fully resolve a hard issue could
   close some of the residual `total_mismatch`/`invoice_number_missing` cases — at the cost of
   one more LLM call only on the documents that still need it (not all documents).

6. **Multi-worker gateway process** (currently `--workers 1`) — this is a reliability/
   availability lever, not an accuracy lever, but worth listing since it was flagged in an
   earlier incident report and never implemented; a stuck request can still freeze the whole
   process for the duration of that request.

---

## 6. Summary

| Question | Answer |
|---|---|
| Current measured accuracy | ~81% pass all deterministic checks outright; most of the remaining 19% are arithmetic/consistency flags, not hallucination |
| Current average latency | ~26s avg / ~17s median (at `consistency=3`) |
| Would a better GPU help? | Yes, specifically for quantization accuracy, context-window ceiling, and cheaper high-`consistency` runs — but it does not fix prompt/logic bugs or inherent document ambiguity |
| Best available lever without upgrading anything | A golden regression test set (process) + OCR table-structure preservation (code) — in that order |
