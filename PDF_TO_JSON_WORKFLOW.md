# PDF → JSON: The Full Workflow, Explained Simply
> Last updated: 2026-08-31 | One complete walkthrough of what happens to a single invoice, start to finish

This is the one-stop explanation: what actually happens between you uploading
an invoice PDF and getting back the final JSON — every step, every LLM call,
and *why* each call happens. Written to be readable without needing to know
the codebase.

---

## The big picture

```
Your PDF
   │
   ▼
① Read the file & pull out text (+ page image if small enough)
   │
   ▼
② Decide HOW to process it (small doc? big doc?)
   │
   ▼
③ Build the instructions for the AI (golden rules + your question)
   │
   ▼
④ CALL #1 — the AI reads the document and writes the JSON
   │
   ▼
⑤ Deterministic double-check (plain code, not AI) — does the math add up?
   │
   ├── Everything checks out ──────────────► Done, return JSON
   │
   └── Something looks wrong
          │
          ▼
      ⑥ CALL #2 — self-correction: AI is told exactly what's wrong, fixes it
          │
          ▼
      Re-check, then return JSON
```

If you asked for extra confidence (`consistency=3` or higher), there's also
a parallel step: a few cheap, tiny extra calls just to double-check the
fields most likely to be wrong (invoice number, invoice date, totals) and
go with whatever most of them agree on. More on that below.

---

## Step ① — Reading the file

The PDF gets opened two ways at once, because neither alone is fully
reliable:

- **Native text extraction** — if the PDF has a real text layer (most
  computer-generated invoices do), this pulls it out directly, no OCR
  needed, very fast and accurate.
- **OCR fallback (PaddleOCR)** — for scanned/image-only pages, or wherever
  the native text layer is missing or garbled, an OCR service actually
  "reads" the page like a photo and extracts text from it.

**If the document is small enough** (roughly: fits comfortably in one AI
call, and isn't too many pages), the actual **page images** also get pulled
out and kept — not just the text. This matters a lot for step ④.

---

## Step ② — Deciding how to process it

Not every document gets treated the same way — the system checks two
things:

- **Is it small enough to send in ONE go?** (under ~80,000 characters of
  text, and 10 pages or fewer for images)
- **If yes** → go straight to Step ③/④ with the whole document at once,
  **and attach the actual page images too** (this is called
  "vision-hybrid" — the AI sees both the text AND a picture of the page,
  so it can catch things pure text can miss: logos, stamps, handwriting,
  and — importantly — the real visual table layout, not just a flattened
  block of text).
- **If it's too big** → the document gets split into chunks (a few pages
  at a time), each chunk is sent to the AI separately in parallel, and
  their answers get merged together afterward ("map-reduce"). Bigger
  documents currently do **not** get page images attached at all — only
  text. This is a known limitation (see `VISION_RECHECK_REQUIREMENTS.txt`
  for the plan to fix it).

---

## Step ③ — Building the instructions

Every extraction call gets the same base instructions (the "golden
rules") plus whatever you actually asked for (the "question"). The golden
rules are a long, carefully-built list of do's and don'ts learned from real
mistakes on real invoices — currently 25+ rules covering things like:

- Never lose a row, never invent one
- A row's amount can be blank — that's still a row, don't merge it into a
  neighbor
- Don't confuse an internal filing number with the actual invoice number
- Don't confuse an unlabelled floating date with the real invoice date
- Flat one-time charges (delivery, protection plan) go in a different
  place than per-item rows
- If a field just points somewhere else ("See Address Below"), go find the
  real value instead of copying the pointer text — *and* instead of just
  leaving the field empty (this half was a real, recurring gap; see
  "What still goes wrong" below)
- ...and more — the full, current list lives in `EXTRACTION_GOLDEN_RULES.md`

This instruction set is the single biggest lever for extraction quality —
almost every fix made recently has been a change to this rule list, not to
the surrounding code.

---

## Step ④ — CALL #1: the actual extraction

**Why this call happens:** this is the only call that's *always* required —
it's the AI actually reading the document and producing the JSON. Every
other call in this whole workflow is optional and only fires when
something needs fixing or double-checking.

Some deliberate choices here, all aimed at getting the SAME answer for the
SAME document every time (as much as is physically possible):
- **Temperature = 0** — "be as deterministic as possible," not creative
- **A fixed seed** — same starting point every run
- These two together get you *close* to consistent output, but not
  perfectly — see the note on GPU-level variance below

### How line items actually get mapped to their amounts

This is the part people usually mean by "how does it know which price goes
with which row" — there's no separate table-detection step (no bounding
boxes, no column-line-finder algorithm). The AI itself does this, guided
by the golden rules, using both the text AND (when available) the actual
picture of the page:

- Read the invoice as a **spatial table** — use left-right/up-down
  position on the page, not just the order text happens to come out in
- A blank amount doesn't mean "not a row" — it stays its own row
- Never let one row's description bleed into the next row's, even if OCR
  text ran them together with no line break
- A code that's genuinely split across two lines (like a truncated item
  code continuing on the next line) gets joined back into one row — but
  only when it's genuinely incomplete, never when it's already a complete
  standalone description that simply has no price this time

This is also the single area with the most *remaining* known issues — see
the "What still goes wrong" section below.

---

## Step ⑤ — The deterministic double-check (no AI involved)

After the AI returns its JSON, plain Python code re-checks it — this step
costs nothing extra and never varies, unlike an AI call:

- Does quantity × unit price ≈ the stated amount, for every row?
- Does the column typing look right (numbers where numbers should be)?
- Are there any exact duplicate rows (common map-reduce artifact)?
- Does the sum of all line items reconcile with the stated subtotal/total?
- Does the row count the AI stated up front match how many rows it
  actually produced?
- Are commonly-expected fields (vendor, buyer, invoice date, invoice
  number) actually present, given the source text clearly has them
  labelled somewhere?

If everything passes, the JSON goes back to you as-is — **no extra AI
call, no extra cost, no extra wait.**

---

## Step ⑥ — CALL #2 (only if needed): self-correction

**Why this call happens:** only when Step ⑤ found something concrete
wrong. The AI gets a second try, but this time it's told *exactly* what's
wrong ("row 4: 5 × 20 = 100, but you wrote amount 90") instead of having to
re-guess the whole document from scratch. Much cheaper and more reliable
than a full re-extraction.

After this, the result gets re-checked one more time (back to Step ⑤'s
logic) so the response can honestly say whether the fix actually landed.

---

## Optional: consistency voting (extra calls, opt-in)

**Why these calls happen:** some fields — invoice number, invoice date,
subtotal, tax, total — have turned out to be the ones most likely to
genuinely flip between two plausible answers on different runs of the
exact same document (this is a real, measured GPU-inference behavior, not
a bug — explained below). If you pass `consistency=3` (or higher) when
calling the extraction API, a few small, cheap extra calls run — each one
asks ONLY for those handful of fields, not the whole document — and
whichever answer the majority agree on wins. Much cheaper than repeating
the entire extraction N times.

---

## Caching: skipping all of the above entirely

**Why this exists:** even with temperature=0 and a fixed seed, re-running
the exact same document can occasionally produce a slightly different
answer — this is a known, real property of how GPUs batch multiple
requests together (explained more in `KV_CACHE_AND_VLLM_WORKFLOW.md`), not
something prompt wording can fully fix.

So: the first time a specific file + specific question is extracted, the
final (validated, possibly self-corrected) result is saved. Any exact
repeat of that same file + same question skips **everything above** —
no OCR, no AI call, no validation — and just returns the saved answer
instantly. This also means: whenever the golden rules themselves get
updated, old cached answers automatically stop being served (the cache
key includes a fingerprint of the current rules), so a fix always applies
to the next request, never gets stuck behind stale cached output.

Want a guaranteed-fresh run instead of a cached one? Pass
`force_refresh=true`.

---

## What still goes wrong (being honest about current limits)

- **Two adjacent rows can still get merged**, even with the page image
  attached and validation passing clean — this has been observed live and
  isn't fully solved yet. It's not a missing-data problem (vision was on),
  it's either the AI misjudging the row boundary or the sheer size of the
  golden-rules instruction set diluting one specific rule among many.
  A deterministic backstop check for this specific pattern is the next
  planned fix.
- **Large documents (map-reduce path) get no page images at all**, only
  text — a real gap, tracked in `VISION_RECHECK_REQUIREMENTS.txt`.
- **Two identical requests can still occasionally disagree** on a
  first-time (non-cached) run — inherent to batched GPU inference, not
  fixable by prompt changes; `consistency=N` is the mitigation for the
  handful of fields most prone to it.
- **Pointer-field resolution reopened 2026-08-31** — the "See Address
  Below" → follow-the-pointer rule (golden rule #15) was marked fixed on
  2026-08-26 after invoice `INV91679` returned the literal pointer text
  as the value. A second invoice (`INV90893`) then hit the *same* gap in
  a different shape: `"ship_to": {}` — empty, instead of either the
  pointer text or the real address printed under "Primary Location" near
  the line items. The model stopped copying the pointer phrase (that part
  held) but never took the actual next step of resolving it, so silently
  omitting the field became the default instead of a genuine last resort.
  Rule #15 has been hardened in `EXTRACTION_GOLDEN_RULES.md` to close this
  specific escape hatch, but — same caveat as the row-merging issue above —
  a validation-pass JSON is not proof the field is actually correct; an
  empty `{}` looks structurally fine and would sail through Step ⑤
  unless a field is contractually required. Worth a deterministic check
  (e.g. flag an empty ship_to/bill_to when the source text contains a
  pointer phrase like "see address"/"see attached") rather than relying on
  the prompt rule alone.

---

## Quick reference: how many AI calls does ONE invoice actually cost?

| Scenario | AI calls |
|---|---|
| Small document, nothing wrong found | **1** |
| Small document, validation catches an issue | **2** (extraction + self-correct) |
| Large document, split into N chunks | **N + 1** (one call per chunk + one merge call), +1 more if self-correction fires |
| Any of the above, with `consistency=3` | + 2 more small/cheap calls |
| Any of the above, but it's a repeat of an identical earlier request | **0** — served from cache |
