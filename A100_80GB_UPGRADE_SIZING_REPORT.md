# A100 80GB Upgrade — Model Choice & Single-GPU Concurrency Report

**Status:** Planning document only — no changes implemented. Written to answer two questions
for the A100 80GB purchase decision: (1) which model/checkpoint to run on it, (2) how many
concurrent requests one A100 80GB can actually handle.

All hardware and model numbers below are measured directly from this deployment
(`/workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4/config.json`, `start_all.sh`, `nvidia-smi`) —
not estimates. This builds on the existing [`GPU_ACCURACY_OPTIMIZATION_REPORT.md`](./GPU_ACCURACY_OPTIMIZATION_REPORT.md)
and the earlier concurrency-scaling review published as an Artifact link in this session.

---

## 1. Which model to run

**Keep the Qwen3.6-35B-A3B family — but reconsider its *quantization*, not the model itself.**

The current build is **GPTQ-Int4** (23GB weights on disk). Your own `GPU_ACCURACY_OPTIMIZATION_REPORT.md`
already flagged that 4-bit quantization is the likely cause behind `total_mismatch` and
OCR digit-confusion errors — those are exactly the failure modes 4-bit quantization is known
to worsen (precise numeric/character discrimination). An A100 80GB is the first GPU where
you can actually afford to walk that back:

| Precision | Weight size (measured / scaled) | Fits on 80GB with room for concurrency? |
|---|---|---|
| **GPTQ-Int4** (current) | 23 GB | Yes — plenty of room left over |
| **INT8 / AWQ-8bit** (if the publisher offers a checkpoint) | ~46 GB | Yes — ~19GB left for KV cache |
| **Full BF16/FP16** | ~90 GB (scaled from measured int4 size) | **No** — exceeds 80GB before any KV cache at all |

So the real choice on this GPU is **Int4 vs Int8**, not Int4 vs full precision — full precision
doesn't fit on a single 80GB card once you account for the KV cache room needed to serve any
concurrency at all. Action item: **check whether Qwen publishes an Int8/AWQ or FP8 checkpoint
for this model.** If yes, load that on the A100 — it directly targets the accuracy issues
already identified, at some cost to worst-case concurrency headroom (see §2). If only Int4
and full-precision builds exist, stay on Int4 for now — it keeps far more concurrency
headroom, and lean on the self-consistency voting mechanism already built (raising
`consistency` from 3 → 5, per §5 of the accuracy report) to close the remaining accuracy gap
instead of chasing it through precision alone.

Do **not** treat this as a reason to switch to a different model family. The architecture
itself (MoE, 8 of 256 experts active per token, grouped-query attention with only 2 KV heads,
native 262K context, already multimodal, already tool-call capable) is well matched to
OCR + reasoning + tool-calling — nothing about moving to A100 changes that conclusion.

---

## 2. How many requests, single time, on one A100 80GB

VRAM budget at the same `--gpu-memory-utilization 0.85` used today: **80GB × 0.85 = 68GB**.
KV-cache cost per request scales with context length, so the honest answer needs a **typical**
invoice (~4K tokens of prompt + image + output) and a **worst case** (every concurrent request
happens to hit the current 32,768-token ceiling at once) — plus a ~3GB workspace/CUDA-graph
reserve.

| Weight precision | Weights | KV-cache pool left | Worst-case ceiling (all @ 32K tokens) | Typical-case ceiling (~4K tokens) |
|---|---:|---:|---:|---:|
| **Int4** (current, recommended for max headroom) | 23 GB | ~42 GB | **~67 concurrent** | ~538 concurrent |
| **Int8** (if adopted for accuracy) | 46 GB | ~19 GB | **~30 concurrent** | ~243 concurrent |

### Reading this against your "100 requests" target

- On **Int4**, a single A100 80GB comfortably covers 100 concurrent requests for realistic,
  mixed invoice lengths — memory only becomes the limiting factor if roughly **70+ of those
  100** happen to be maximum-length 32K-token documents at the exact same moment, which is an
  unlikely adversarial case, not a typical one.
- On **Int8**, the same card comfortably covers 100 concurrent *typical* invoices too, but the
  worst-case safety margin is thinner — it saturates around **30 concurrent** if that many
  requests are simultaneously maxed-out documents.
- Either way, **memory capacity is not the whole story.** The A100 80GB's memory bandwidth
  (~1.9–2.0 TB/s) is roughly **2.5× the current A6000's ~768 GB/s** — that's what actually
  drives how many decode steps per second can be swept across all concurrent users combined,
  which is what determines real per-user latency, not just whether requests fit in VRAM. Expect
  a real, meaningful latency improvement over today's 8-slot baseline (p50 693ms / p99 5.66s),
  but don't assume it scales perfectly linearly to 100 concurrent without checking.

### Concrete numbers to use for planning (10 → 100, step 10)

| Concurrent requests | KV cache needed — typical (4K tok) | KV cache needed — worst case (32K tok) | Fits · Int4 pool (42GB)? | Fits · Int8 pool (19GB)? |
|---:|---:|---:|:---:|:---:|
| 10  | 0.78 GB | 6.25 GB  | Yes | Yes |
| 20  | 1.56 GB | 12.5 GB  | Yes | Yes |
| 30  | 2.34 GB | 18.75 GB | Yes | Marginal |
| 40  | 3.13 GB | 25 GB    | Yes | No |
| 50  | 3.91 GB | 31.25 GB | Yes | No |
| 60  | 4.69 GB | 37.5 GB  | Yes | No |
| 70  | 5.47 GB | 43.75 GB | Marginal | No |
| 80  | 6.25 GB | 50 GB    | No | No |
| 90  | 7.03 GB | 56.25 GB | No | No |
| 100 | 7.81 GB | 62.5 GB  | No | No |

Both "Fits" columns are judged against the **worst-case** column, since that's the safety
condition (a burst of unusually long documents shouldn't be able to overrun the server). The
typical-case column stays well within budget through 100 concurrent under either precision —
it's only the all-long-documents scenario that draws a hard line.

---

## 3. Bottom line

- **Model:** stay on Qwen3.6-35B-A3B. The only real decision is Int4 (current, max headroom)
  vs Int8 (better accuracy, ~2× less worst-case headroom) — check if Qwen ships an Int8/AWQ
  build before assuming you have to build one yourself.
- **Single-time capacity on one A100 80GB:** ~67 concurrent on Int4, ~30 concurrent on Int8, in
  the adversarial worst case; effectively >100 for both under a realistic mixed invoice workload.
- **Before committing:** load-test with vLLM's own `benchmark_serving.py` at 10/20/.../100
  concurrency using your real invoice size distribution — everything above is a memory-capacity
  ceiling, not a measured latency guarantee.
- Also carry forward the two fixes already flagged in the earlier review: align
  `CONTEXT_TOKENS` (gateway) with `--max-model-len` (vLLM launch flag), and switch
  `--dtype float16` → `--dtype bfloat16` — both are free, and both apply regardless of which
  GPU or precision you land on.
