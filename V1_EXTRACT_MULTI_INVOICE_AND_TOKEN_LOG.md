# `/v1/extract` Investigation Log — American Wear Multi-Invoice Document

**File investigated:** `logs/V0020990-10370477.pdf` (6 pages)
**Reported symptom:** "Only 26 of 84 line items extracted" / "LLM issue"

## Finding 1 — This is not one invoice. It's five, bundled in one PDF.

Direct OCR of every page confirms:

| Page | Content |
|---|---|
| 1 | Invoice **#10370477-0105** |
| 2 | Invoice **#10370477-0205** |
| 3 | Invoice **#10370477-0305** |
| 4 | Invoice **#10370477-0405** |
| 5 | Invoice **#10370477-0505** |
| 6 | Email approval thread (covers all 5, account #223300) |

Same customer (HYTORC UNEX), same account (223300), same garment category (LADIES LOCKER
ROOM #500-599) — but **five distinct invoice numbers**, each almost certainly covering a
different slice of the full ~84-person roster.

`/v1/extract`'s document-segmentation rule (added earlier this session specifically to stop
a different bundled-document contamination bug) correctly identifies multiple documents in
the packet and extracts only the one matching the file's primary invoice number — listing the
other four as a `metadata.page_invoices` reference instead of merging their rows in. **This
is the rule working as designed**, not a bug — it just hadn't been exercised against a
genuinely multi-invoice bundle before.

The "84 (Dynamic mode) vs 26 (`/v1/extract`)" comparison in the original report was comparing
two different behaviors, not one tool succeeding and one failing: Dynamic mode appears to
flatten all pages into one pass without honoring document boundaries, so it naturally
combines all 5 invoices' rosters into one list. `/v1/extract` deliberately does not do that.

**Correct usage going forward:** call `/v1/extract` once per invoice number (or page), and
combine results client-side — or phrase the question explicitly ("extract ALL invoice numbers
present, as separate entries") to override the single-document default when a combined dump
is actually wanted.

## Finding 2 — A real, separate bug: output truncation was undetected

Independent of the multi-invoice issue, tracing this file's actual `/v1/extract` calls
uncovered that `finish_reason` (whether the model's output got cut off) was **never checked
anywhere in the code** — a document with enough rows could have its JSON silently truncated
mid-generation and the partial result kept as if complete.

**Fixed:** added `finish_reason` detection (`OutputTruncated` exception) plus escalating
retries (8192 → 24000 → 30000 tokens) at all 4 call sites that generate a final answer
(`vision_hybrid`, `single_pass`, the `map_reduce` combine step, self-correction).

## Finding 3 — A related discovery: this document's vision-hybrid call nearly exhausted the entire context on INPUT alone

New per-call telemetry (see below) on this exact file showed:

```
prompt_tokens: 27,786   completion_tokens: 4,982   total: 32,768 (= the model's hard ceiling)
finish_reason: length   (truncated)
```

27,786 input tokens for a 6-page document is very high — the 6 rendered page images are
consuming the overwhelming majority of the context budget, leaving almost no room for output
regardless of what `max_tokens` is requested. This is why the escalating-`max_tokens` retry
alone didn't help on the vision path here: the constraint wasn't output budget, it was input
size. The system correctly fell back to the text-only path (`single_pass_after_vision_overflow`),
which used a much smaller prompt (7,088 tokens) and succeeded.

**Not yet fixed — worth a decision:** whether to reduce image render resolution for
high-page-count vision_hybrid calls, or lower `MAX_VISION_PAGES`/`SINGLE_SHOT_CHARS` further to
route image-heavy multi-page docs to text-only sooner, trading some vision-grounding accuracy
for reliably fitting in context.

## New logging added: `logs/extraction_telemetry.jsonl`

Every LLM call inside the extraction pipeline now logs:
```json
{"kind": "llm_call", "max_tokens_requested": 8192, "prompt_tokens": 27786,
 "completion_tokens": 4982, "total_tokens": 32768, "finish_reason": "length",
 "truncated": true, "ts": "..."}
```

And every completed document extraction logs a summary:
```json
{"kind": "document_summary", "filename": "...", "pages": 6, "doc_text_chars": 7569,
 "images_attached": 0, "strategy": "single_pass_after_vision_overflow",
 "answer_chars": 1192, "validation_ok": false, "corrected": true, "ts": "..."}
```

This makes future truncation/context/token issues immediately diagnosable from the log alone,
without needing to reproduce and manually trace a specific document again.

## Remaining open issue on this specific file

Even after falling back successfully to text-only, the final result for invoice `10370477`
only captured 3 line items (flat fees: hang-locker, protection-plus, delivery) and flagged
`total_mismatch` (line items sum 194.95 vs stated subtotal 378.4) — meaning the per-employee
weekly-rate charges that make up the bulk of that invoice's own subtotal are still missing
from THIS specific single-invoice extraction, separate from the multi-invoice-bundle question.
This is validated as `validation.ok: false` and correctly flagged for review, not silently
accepted — but not yet root-caused further.
