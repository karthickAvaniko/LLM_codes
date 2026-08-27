# Issue: `/v1/extract` Timeouts Under Concurrent Load (Partial Results)

## Summary

When processing a multi-page invoice, the client application splits the PDF into one API
call per page and sends all pages in parallel, with `consistency=3` set on each call. Some
of those parallel calls exceed the client's 120-second read timeout and fail, while the
rest succeed — the application then silently returns a **partial result** (missing the
pages that timed out), which shows up downstream as missing line items.

## Root Cause

This is a **concurrency/capacity mismatch**, not a network fault or random server slowness.

- The vLLM inference server is configured for a maximum of **8 concurrent sequences**
  (`--max-num-seqs 8`) on a single GPU.
- `consistency=3` makes **one** extraction call internally run **3** concurrent LLM
  passes (self-consistency voting).
- Splitting a 6-page document into 6 parallel per-page calls, each with `consistency=3`,
  generates **18 concurrent sequence requests** against a server that can only actively
  process 8 at once.
- The excess requests queue behind the 8 that are running. Queued requests that don't get
  scheduled within the client's 120-second timeout window fail with a read timeout.
- The application's own fallback logic (if fewer than half the page-chunks fail) returns
  a partial JSON instead of raising an error — so the failure is silent from the user's
  point of view, surfacing only as incomplete data.

## Why It's Intermittent

Whether a given request times out depends on scheduling order and how many other calls are
in flight at that moment — this is why the same document sometimes succeeds fully and
sometimes doesn't: it is a load-dependent queueing effect, not a deterministic bug in either
the extraction logic or the model.

## Recommended Fixes (in order of effort)

1. **Stop splitting documents into per-page calls.** The extraction endpoint already
   handles up to 10 pages in a single call natively. Sending the whole PDF once instead of
   6 separate page requests reduces load by 6x and removes the failure mode entirely.
2. **Limit client-side concurrency.** Cap simultaneous outgoing requests to 2–3 at a time
   rather than firing all pages at once.
3. **Lower `consistency` for high-volume traffic** (e.g. 3 → 1 or 2) to raise the number of
   requests that can run truly in parallel without queueing.
4. **Increase the client's read timeout** (e.g. 120s → 300s) so a request that is merely
   queued, not stuck, has time to complete instead of being treated as failed.
5. **(Infra, optional)** Increase `--max-num-seqs` on the inference server if GPU memory
   headroom allows, or add a second GPU/instance for true horizontal capacity.

## Bottom Line

The extraction service is not silently dropping data on its own — the timeouts are a direct,
predictable consequence of how the client currently issues requests (page-splitting combined
with 3x self-consistency, multiplying real concurrent load by up to 18x per document). Fixing
the calling pattern (items 1–3 above) resolves this without any infrastructure changes.
