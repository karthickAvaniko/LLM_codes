# Why Direct-API Extraction Accuracy Is Lower Than the Chatbot's

**Finding:** Checked live production logs (`/workspace/logs/requests.jsonl`) going back to 2026-08-20. The same client IP (`210.18.157.215`) has been calling `POST /v1/extract` **once per page**, splitting each multi-page document into N separate single-page requests — continuing as recently as 2026-08-22. This is almost certainly the root cause of the accuracy gap. Real log entries, verbatim:

```
"question": "This file contains ONLY page 6 of a 6-page document — the rest
was sent as separate requests. Extract everything visible on page 6 as JSON,
including a continuation of a table that started on an earlier page."
```

Same pattern repeated for pages 1, 2, 3, 4, 5 as **separate HTTP requests**, each treating one page as if it were the whole document.

---

## 1. The two paths, side by side

| | **"Direct API" path (low accuracy)** | **Chatbot path (correct accuracy)** |
|---|---|---|
| Endpoint | `POST /v1/extract` | `POST /files/ask` |
| What's sent per call | **One page** of the document, pre-split client-side | **The whole PDF**, all pages, one file |
| Number of LLM extraction calls per document | **N** (one per page) — no shared context between them | **1** (or a few, only if the whole doc exceeds 40,000 chars — handled server-side, not by you) |
| System prompt | `DOC_SYSTEM` + `EXTRACTION_RULES` | `DOC_SYSTEM` + `EXTRACTION_RULES` (**identical** — this is not the difference) |
| Model / temperature / seed | Same model, temp 0, seed 42 | Same model, temp 0, seed 42 (**identical**) |
| Validation (`validate_extraction`) | Runs **per page-fragment** | Runs **per whole document** |
| Vision-hybrid | Attempted per single-page image | Attempted with the real full document context |

The model, the prompt rules, the validation code — **all identical**. The only real difference is what arrives at the model: one page in isolation vs. the whole document at once.

---

## 2. Why splitting into pages directly causes lower accuracy

The gateway's extraction prompt (`EXTRACTION_RULES`) explicitly depends on **whole-document context** for several of its correctness rules:

- **"Whole-page coverage"** — vendor/seller name, address, and header fields (invoice number, dates) are meant to be captured once and associated with every line item. When page 6 is sent alone, the model has never seen page 1's header — it can't attach the correct vendor/invoice-number/date to page 6's rows unless that information happens to repeat on every page (rare).
- **Primary invoice-number/date disambiguation** — this rule tells the model to distinguish the real invoice number from a PO/job/routing number by cross-referencing labels elsewhere on the document. A single isolated page often doesn't carry that disambiguating context.
- **`total_mismatch` validation** — reconciles line-item sum against the stated subtotal/tax/total. If the totals block is on the last page and the line items are split across pages 1-5, **each individual page-request's validation either has no totals to check against, or incorrectly flags a mismatch** because it's only seeing a fragment of the real line-item list.
- **`duplicate_row` / continuation handling** — a table row that wraps or continues from the previous page needs the model to know it's a continuation, not a new item. The prompt does tell it "this is a continuation" as plain text, but the model still never sees the actual prior rows to check for duplication or correct sequencing.
- **Self-consistency and self-correction** operate on each page-fragment independently — there's no reconciliation step across the N separate API responses. If page 3's extraction disagrees with page 5's extraction about the vendor name, nothing catches that; the client has to merge N independent JSON objects itself afterward, which is extra work that itself can introduce errors.

None of this is a bug in the gateway — it's the direct, predictable consequence of asking the model to extract structured data from **1/6th of a document at a time**, when the extraction rules were written assuming it can see the whole thing.

---

## 3. Why the chatbot doesn't have this problem

When a file is dropped into the chat UI, `/files/ask` reads **all pages of the file in one call**:

```python
pages, names = await extract_all()   # every page of the uploaded file, together
...
messages = _vision_doc_messages(fname, doc_text, images, question)   # or _doc_messages
```

The model sees the entire document (or, for very large documents, the server's own internal map-reduce splits it — which is a *server-side*, context-aware chunking that later **recombines** the partial findings into one coherent answer via `_reduce_messages()`, unlike client-side page-splitting which never recombines anything). Validation then runs once, against the complete extracted JSON, so `total_mismatch`, vendor/date presence, and duplicate-row checks all have the full picture to check against.

---

## 4. Fix: stop splitting the PDF client-side

**`/v1/extract` already accepts the whole PDF as a single file** — there is no need to pre-split into pages at all:

```bash
curl -X POST https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1/extract \
  -H "Authorization: Bearer ak-<your-key>" \
  -F "files=@full_invoice.pdf" \
  -F "question=Extract every field as JSON, including all line items"
```

- If the document is small, this becomes one internal LLM call (or a vision-hybrid call if it qualifies) with full context — exactly what the chatbot does.
- If the document is large (>40,000 characters of extracted text), the server automatically does its own internal map-reduce **and reconciles the pieces into one final answer before validating** — you get the benefit of chunking without losing cross-page reconciliation, because the server's reduce step (`_reduce_messages`) is specifically designed to merge partial findings, unlike independent client-side calls.
- `MAX_BATCH_FILES = 20` means you can even send multiple *separate* documents in one request if needed — but each individual document should be sent whole, not pre-cut into pages.

**Action:** update whatever client script is generating the "page N of M" requests (the one hitting the gateway from `210.18.157.215`) to send each full document as a single `files=` upload instead of splitting it into per-page calls first. This should close most of the accuracy gap, since it removes the exact mechanism (lost cross-page context) that the evidence above points to.

*(Note: this exact page-splitting pattern, combined with high `consistency` values, was already flagged once before in `ISSUE_CONCURRENT_REQUESTS_TIMEOUT.md` as a source of client-side timeouts — this is a second, independent problem caused by the same root habit.)*
