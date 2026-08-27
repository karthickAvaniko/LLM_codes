# `/files/ask` — System Prompt (verbatim, live source)
> Last updated: 2026-08-26 | Source: `gateway/main.py` — `DOC_SYSTEM` (~line 662), `EXTRACTION_RULES` (~line 675), `_doc_messages()`/`_vision_doc_messages()`/`_reduce_messages()` (~line 1054-1118)

`/files/ask` (the built-in chatbot UI's file-attachment endpoint) does **not**
have its own separate system prompt. It calls the exact same message-building
functions as `/v1/extract` — `_doc_messages()`, `_vision_doc_messages()`,
`_reduce_messages()` — so the system prompt is identical between the two
endpoints. See `EXTRACTION_GOLDEN_RULES.md` Part 1 for the full endpoint
comparison.

---

## The rule that decides everything: `_wants_json()`

```python
def _wants_json(question: str) -> bool:
    q = (question or "").lower()
    return any(k in q for k in ("json", "structured data", "schema"))
```

Every system prompt below is built as:

```python
system = DOC_SYSTEM + (EXTRACTION_RULES if _wants_json(question) else "")
```

So the system prompt is **dynamic per request** — it depends on whether the
user's question (or `/v1/extract`'s `question` field, default `"Extract all
information as structured JSON"`) contains the word "json", "structured
data", or "schema". Ask a plain question → base prompt only, prose answer.
Ask for JSON → base prompt + the full extraction rule set.

---

## 1. Base prompt — `DOC_SYSTEM` (always present)

```
You are a helpful document assistant. Answer the user's request using the
document content provided, and be accurate. IMPORTANT: reply in the format
the user asks for — if they ask you to analyse, explain, summarize, or
answer a question, reply in clear plain language (prose), NOT JSON. Only
output JSON when the user explicitly asks for JSON or structured data
extraction.
```

## 2. Extraction addendum — `EXTRACTION_RULES` (only when `_wants_json()` is true)

Appended directly after `DOC_SYSTEM` (no separator, one continuous system
message). Full text: see `EXTRACTION_GOLDEN_RULES.md` Part 2 — this is the
same 23-rule set (line-item purity, the new charges-vs-line_items split,
invoice number/date rules, row-count preamble, output purity, etc.) word for
word, since it's the same Python constant.

---

## 3. Where this system prompt gets used, and how the user message differs

`/files/ask` picks one of these paths depending on document size
(`SINGLE_SHOT_CHARS` threshold) and whether vision-hybrid is eligible:

### 3a. Single-shot, text-only — `_doc_messages()`
```python
[
  {"role": "system", "content": DOC_SYSTEM + (EXTRACTION_RULES if json-ish else "")},
  {"role": "user", "content": f"Document: {fname}\n\n{doc_text}\n\nTask: {question}"},
]
```

### 3b. Single-shot, vision-hybrid — `_vision_doc_messages()`
Same system prompt. User message becomes a multi-part content list: OCR text
first (for precise numbers), then the actual page images as `image_url`
parts (base64 PNG) — so the model can visually cross-check logos, stamps,
seals, and handwriting that OCR text alone can't represent.
```python
[
  {"role": "system", "content": DOC_SYSTEM + (EXTRACTION_RULES if json-ish else "")},
  {"role": "user", "content": [
      {"type": "text", "text": "Document: {fname}\n\nOCR/extracted text (...)\n\n{doc_text}\n\nTask: {question}"},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}},
      ...  # one per page image
  ]},
]
```

### 3c. Large document — map phase — `_map_chunks()` → `_doc_messages()` per chunk
Same system prompt as 3a, but the **user task text is rewritten** per chunk
to keep the model from guessing about pages it can't see:
```
{question}

IMPORTANT: You only see pages of a larger document. Report ONLY what is
explicitly written in these pages, citing the page number. If something
asked for is not in these pages, write 'NOT FOUND in these pages' for that
item — never guess or infer it.
```
Each chunk's `_doc_messages()` call also gets a `part` label
(`"pages {a}-{b} of a larger document"`) appended to the `Document:` intro line.

### 3d. Large document — reduce phase — `_reduce_messages()`
Same system prompt again. User message merges the chunk findings:
```
Document: {fname} — it was analyzed in {N} parts. Below are the findings
from each part.

{joined findings}

Task: Combine all findings into one complete, final answer (merge
duplicates, keep page references where useful). Ignore any 'NOT FOUND in
these pages' entries when another part found the answer; prefer findings
with explicit page citations. Original task: {question}
```
If the combined findings are still too large (>60K chars, >3 partials), a
hierarchical reduce runs first, groups of 5 partials at a time (own `_llm()`
call, `max_tokens=2048`, no schema) before the final reduce.

---

## 4. Validation + self-correction now apply to ALL sizes, not just single-shot *(fixed 2026-08-26)*

Until 2026-08-26, `/files/ask` only ran `validate_extraction()` +
`_self_correct()` (the same deterministic safety net `/v1/extract` always
uses — catches a dropped vendor field, a column shift, an arithmetic
mismatch, or a wrong document-shape decision) when the document was small
enough to fit in a single LLM call. A document forced into the map-reduce
path (large invoices, many pages) got **no validation and no self-correction
at all** — it streamed the raw reduce-call output straight to the client.
This was a real gap: it meant the exact same document could come back
meaningfully more reliable through `/v1/extract` than through the Console
UI, purely because of its size.

**Fixed:** the gate is now `_wants_json(question)` alone, not
`single_shot and _wants_json(question)`. `messages` is already fully built
by the time this check runs (either `_doc_messages()`/`_vision_doc_messages()`
for single-shot, or `_reduce_messages()`'s final combine call for map-reduce),
so validation/self-correction now runs identically regardless of document
size. This is what caught and would now correct the real failure mode
documented in `EXTRACTION_GOLDEN_RULES.md` rule #18 — a multi-page invoice
that got incorrectly split into 5 fake invoice objects on one run went
through this exact map-reduce path with no safety net at the time.

## 5. Result caching, same as `/v1/extract` *(added 2026-08-26)*

`/files/ask` now also caches by a hash of (all uploaded files' bytes,
concatenated in upload order + the question). Same file(s) + same question
→ the exact cached answer is replayed as token events immediately, skipping
OCR and inference entirely, instead of re-running the pipeline and risking a
different result on the model's normal run-to-run variance (see
`EXTRACTION_GOLDEN_RULES.md` Part 3 for why that variance exists even at
temperature=0 with a fixed seed). Only active when `_wants_json(question)` —
plain free-form questions about a document are never cached, since a
different phrasing of the same underlying question is expected to answer
differently on purpose.

---

## Not the same as `/chat`

The plain-text browser chat (`/chat`, no file attached) uses a **completely
different** system prompt — `IDENTITY_PROMPT` (Avaniko assistant identity) +
a live date/time line — not `DOC_SYSTEM`/`EXTRACTION_RULES` at all. Those
only apply once a document is actually in play (`/files/ask`, `/v1/extract`,
`/v1/ask`, `/v1/files/{fid}/ask`).
