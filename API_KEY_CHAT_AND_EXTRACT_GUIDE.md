# Avaniko AI Gateway — API Key, Conversation & Full `/v1/extract` Guide

One document, three parts: get a key, talk to the model, and a complete A-to-Z walkthrough of `/v1/extract` — every function it calls, how concurrency actually works, how OCR and invoice-to-JSON extraction happen internally, and every validation rule applied to the output.

All facts below come from reading the live `gateway/main.py` (line numbers included) and running real requests against the live gateway on 2026-08-21.

---

## Part 1 — Get an API key

| Route | Status | Use it? |
|---|---|---|
| `POST /signup/key` (behind `/getkey`) | **Closed** — `AVANIKO_SELF_SIGNUP` env var not set. Confirmed live: `{"error":{"message":"Self-service signup is currently closed..."}}` | No |
| `POST /admin/keys` (master key, terminal) | Works | **Yes — fastest** |
| `/keys` admin console (browser) | Works | Yes — visual |

```bash
curl -X POST http://localhost:7778/admin/keys \
  -H "Authorization: Bearer $(cat /workspace/gateway/.api_key)" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-app","rpm_limit":60,"daily_limit":5000}'
```
The `api_key` in the response is shown **once** — it's stored hashed and can't be retrieved again through the API.

---

## Part 2 — Have an LLM conversation

`POST /v1/chat/completions`, header `Authorization: Bearer ak-<your-key>`.

Live-verified single call:
```bash
curl -X POST http://localhost:7778/v1/chat/completions \
  -H "Authorization: Bearer ak-<your-key>" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say OK if you can hear me, one word only."}],"task":"chat"}'
```
```json
{"id":"chatcmpl-b7fc8a9d000fcb60","model":"avaniko-ai",
 "choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}],
 "usage":{"prompt_tokens":362,"completion_tokens":2,"total_tokens":364}}
```

**The API is stateless.** A "conversation" is just resending the growing `messages` array each turn, appending the assistant's last reply before the next question:
```python
conversation = [{"role":"user","content":"My invoice number is INV-4471. Remember that."}]
r1 = post(conversation); conversation.append({"role":"assistant","content":r1_text})
conversation.append({"role":"user","content":"What invoice number did I just give you?"})
r2 = post(conversation)   # → correctly answers "INV-4471"
```
Add `"stream": true` for token-by-token SSE. If history outgrows the 32,768-token context window, the gateway auto-trims the oldest messages instead of erroring.

---

## Part 3 — `/v1/extract`, complete A-to-Z

### 3.1 What it is

`POST /v1/extract` — batch document-to-JSON extraction. Send up to 20 files (PDF, image, docx, xlsx, txt/csv) in one multipart request; get back structured JSON per file, each one independently validated and self-corrected. This is the endpoint behind "invoice to JSON."

### 3.2 Request spec

Multipart/form-data, **not** raw JSON.

| Field | Type | Default | Purpose |
|---|---|---|---|
| `files` | file, repeatable | required | up to 20 files, 50MB each |
| `question` | text | generic extraction prompt | what to extract |
| `hints` | text | `""` | per-document OCR-quirk notes (e.g. "column J is often misread as 313") |
| `output_schema` | text | `""` | a JSON Schema string — constrains the model's output via vLLM guided decoding, so it can never emit invalid JSON or skip a required field |
| `consistency` | text (int, 1–5) | 1 | run the extraction N times, majority-vote merge the fields |
| `canonicalize` | text (bool) | false | normalize field names semantically after extraction |

```bash
curl -X POST http://localhost:7778/v1/extract \
  -H "Authorization: Bearer ak-<your-key>" \
  -F "files=@invoice.pdf" \
  -F "question=Extract invoice_no, total_amount as JSON"
```

### 3.3 Concurrency — how many requests can actually run

There are **three separate concurrency limits stacked on top of each other** — understanding all three matters if you're batching a lot of documents:

1. **Within one `/v1/extract` call**: files are processed with `asyncio.Semaphore(5)` — at most **5 files at a time** inside a single request, even if you sent 20. The rest queue behind those 5.
2. **Self-consistency multiplies calls per file**: `consistency=3` means each of those 5 concurrently-processing files fires **3 parallel LLM calls each** — so one `/v1/extract` request can generate up to `5 × consistency` simultaneous LLM generations on its own.
3. **The real, global bottleneck — vLLM itself**: the model server is launched with `--max-num-seqs 16`. This cap is shared across **every endpoint and every API key on the pod at once** (`/v1/extract`, `/v1/chat/completions`, `/v1/ask`, everything) — it is not per-request or per-key. The 17th simultaneous generation anywhere on the gateway queues inside vLLM, regardless of which endpoint asked for it.

**Real incident this caused** (documented in `ISSUE_CONCURRENT_REQUESTS_TIMEOUT.md`): a client was splitting PDFs into one request per page, each with `consistency=3`, multiplying real concurrent LLM sequences up to ~18× against what was then an 8-generation cap — vLLM correctly queued the overflow, but the client's own 120-second HTTP timeout fired first, producing silent partial results. The fix was on the client side (don't multiply page-splitting × high consistency); the cap is now 16, which gives more headroom but the same math still applies at large enough scale.

**Practical guidance:** if you must send many files with `consistency > 1`, either lower consistency for bulk batches or send fewer files per request and let your own client queue the rest — don't rely on the server to absorb unlimited fan-out.

Also gating every request regardless of GPU capacity: **per-key rate limits** (`rpm_limit`, `daily_limit`, set when the key was created) and the file-count guard `MAX_BATCH_FILES = 20` (over that, the request is rejected outright with a 400 before any processing starts).

### 3.4 Step-by-step: what happens inside one `/v1/extract` call

```
1. Per file (5 at a time):
     a. extract_pages()          → text, page by page
     b. extract_page_images()    → page images, page by page
     c. decide: vision_hybrid or text-only map_reduce?
     d. one_pass() × consistency → call the LLM (1 or N times)
     e. if N>1: _merge_by_vote() → majority-vote merge
     f. _try_json() + _dedupe_duplicate_values()
     g. validate_extraction()    → up to 14 deterministic checks
     h. if hard issues: _self_correct() → one correction LLM pass → re-validate
     i. if canonicalize=true: canonicalize_fields()
2. Aggregate all file results, log to requests.jsonl, return JSON.
```

### 3.5 OCR & text extraction — `extract_pages()` (`main.py:475`)

Dispatches by file extension:

| File type | How text is extracted |
|---|---|
| `pdf` | **PyMuPDF** (`fitz`) reads native text per page first. Any page with **under 300 characters** of native text gets that page rendered to a PNG (2× zoom) and sent to the OCR microservice (`ocr_image()`, `main.py:461`, a blocking `httpx.post` to the isolated OCR service on port 7780) — whichever of {native text, OCR text} is **longer** wins, per page. This means a mostly-digital PDF with one scanned page still gets that one page OCR'd correctly, and a page with just a small stamp/header (which used to clear an older, lower threshold and skip OCR entirely — silently losing a table rendered as an image) is now caught. |
| `png / jpg / jpeg / webp / bmp / tiff` | Whole image sent straight to `ocr_image()` |
| `docx` | Parsed with `python-docx` — paragraphs + tables (rows joined with `|`) |
| `xlsx / xls` | Parsed with `pandas`, each sheet converted to CSV text, one "page" per sheet |
| `txt / csv / other` | Decoded as UTF-8 and split into ~10,000-character pseudo-pages so later chunking can still work on page boundaries |

`ocr_image()` fails soft — any OCR error returns an empty string rather than raising, so one broken page doesn't kill the whole document.

### 3.6 Page image rendering — `extract_page_images()` (`main.py:542`)

Renders each page as a PNG for the model's **native vision** (this is a real capability of the underlying model, not a separate vision API). Pages that look like dense tables (many short lines — the exact shape where small-print decimals get misread) render at **3× zoom**; everything else at **2×**. This is what lets the model literally see a stamp, logo, or handwriting that OCR text alone throws away.

### 3.7 Vision-hybrid vs. text-only — the actual decision

```python
use_vision = bool(images) and len(images) <= MAX_VISION_PAGES and len(doc_text) <= SINGLE_SHOT_CHARS
```
- `MAX_VISION_PAGES = 10` — documents over 10 pages skip vision (image tokens get expensive fast)
- `SINGLE_SHOT_CHARS = 40,000` — documents whose OCR/native text exceeds ~40k characters skip vision too

**Vision-hybrid** (small/simple docs): sends the model the OCR text **and** the actual page images together in one call (`_vision_doc_messages`, `main.py:898`) — the model cross-checks a misread digit against what it can literally see.

**Text-only map-reduce** (`answer_document()`, `main.py:948`) — for everything else:
- ≤40,000 chars → one single LLM call with the whole document
- \>40,000 chars → `_chunk_pages()` (`main.py:877`) splits into ≤35,000-char chunks → `_map_chunks()` (`main.py:919`) answers each chunk in parallel (concurrency 4, each instructed to cite page numbers and say "NOT FOUND" rather than guess) → results are combined hierarchically in groups of 5 until short enough for one final LLM call via `_llm_retry_truncation()` (`main.py:850`)

If vision-hybrid hits a context overflow anyway (image tokens aren't counted by `SINGLE_SHOT_CHARS`, which only budgets text), it falls back to the text-only path automatically rather than failing the request.

### 3.8 Self-consistency voting (`consistency` param)

With `consistency > 1`, N independent extraction passes run in parallel per file. Merge logic (`_merge_by_vote()`, `main.py:2026`):
- If the JSON samples share the **same top-level key shape**, fields are deep-merged by **majority vote** per field.
- If they *don't* agree on shape, the samples are **not** blindly unioned (that could let two contradictory values for the same real fact survive under two different field names) — instead, the single sample with the **fewest hard validation issues** is kept.

### 3.9 Deterministic validation — `validate_extraction()` (`main.py:2144`)

After the LLM produces JSON, **14 independent, code-based checks** run — none of these depend on the model being right twice:

| Check | Catches |
|---|---|
| `not_json` | Output wasn't valid JSON at all |
| `empty_line_item` | A row with no description, quantity, price, or amount — not a real row |
| `wrong_amount` | `quantity × unit_price ≠ amount` (with an exception for subscription/period billing where amount legitimately equals unit_price alone) |
| `wrong_column` | A numeric field holds text or vice versa — usually a column shift |
| `duplicate_row` | Identical item/description/amount repeated (common map-reduce artifact on multi-page docs) |
| `total_mismatch` | Line items don't sum to the stated subtotal, or subtotal+tax don't sum to the stated total |
| `subtotal_as_line_item` | A row's amount equals the invoice subtotal — usually the subtotal leaking in as a fake line (exempt for genuinely single-line invoices) |
| `vendor_missing` | Vendor name detected in source text but absent from output |
| `buyer_missing` | Buyer/bill-to detected in source but absent from output |
| `invoice_date_missing` | Same, for invoice date |
| `due_date_missing` | Same, for due date |
| `invoice_number_missing` | No invoice number in the output |
| `currency_missing` | Soft check — no currency indicated |
| `missing_row` | Heuristic — a value/code pattern in the source text with no matching row in the output |

Each issue carries a `severity` (`hard` vs. soft/heuristic) — only **hard** issues trigger self-correction.

### 3.10 Self-correction (`_self_correct()`, `main.py:2331`)

If validation finds any hard issue, the gateway makes **exactly one** automatic correction LLM call — given the original document (plus the original page images, if vision was used) and the precise list of issues found — then re-runs `validate_extraction()` on the corrected output. The response's `validation.corrected` field tells you whether this happened, and `validation.issues_before_correction` (when present) shows what was originally wrong.

### 3.11 Canonicalization (optional) — `canonicalize_fields()` (`main.py:2099`)

If `canonicalize=true`, a final pass semantically normalizes field names (similarity threshold 0.42) so, e.g., `invoice_no` and `invoice_number` from different documents converge to one name — useful when batch-processing invoices from many different vendors with inconsistent field naming. Renames are reported in the response's `field_renames`.

### 3.12 Full response shape

```json
{
  "question": "Extract invoice_no, total_amount as JSON",
  "files": 1,
  "ms": 4230,
  "results": [
    {
      "filename": "invoice.pdf",
      "pages": 1,
      "strategy": "vision_hybrid",
      "answer": "{\"invoice_no\": \"...\", \"total_amount\": \"...\"}",
      "validation": { "ok": true, "issues": [], "corrected": false },
      "field_renames": {}
    }
  ]
}
```
`strategy` tells you which path was taken: `vision_hybrid`, `single_pass`, `map_reduce`, or a `+consistency{N}` / `_after_vision_overflow` suffix. A per-file failure (unreadable file, too large) never fails the rest of the batch — it just returns `{"filename":..., "error":"..."}` for that one entry.

### 3.13 Function map — everything `/v1/extract` calls, in order

| Function | Line | Role |
|---|---|---|
| `batch_extract()` | `main.py:2358` | The route handler itself |
| `extract_pages()` | `main.py:475` | Per-page text extraction (native + OCR fallback) |
| `ocr_image()` | `main.py:461` | Blocking call to the OCR microservice |
| `extract_page_images()` | `main.py:542` | Render pages as PNG for vision |
| `_vision_doc_messages()` | `main.py:898` | Build the vision-hybrid LLM prompt (text + images) |
| `answer_document()` | `main.py:948` | Text-only single-shot or map-reduce fallback |
| `_chunk_pages()` | `main.py:877` | Splits a large document into ≤35k-char chunks |
| `_map_chunks()` | `main.py:919` | Answers each chunk in parallel |
| `_llm_retry_truncation()` | `main.py:850` | Escalates `max_tokens` and retries on truncated output |
| `_pages_text()` | `main.py:874` | Joins page list into one text blob |
| `_merge_by_vote()` | `main.py:2026` | Merges N self-consistency samples |
| `_try_json()` | `main.py:1932` | Safely parses model output as JSON |
| `_dedupe_duplicate_values()` | `main.py:1970` | Strips accidental duplicate values in the parsed JSON |
| `validate_extraction()` | `main.py:2144` | Runs the 14 deterministic checks |
| `_self_correct()` | `main.py:2331` | One corrective LLM pass on hard validation failures |
| `canonicalize_fields()` | `main.py:2099` | Optional semantic field-name normalization |

### 3.14 Invoice-to-JSON specific behavior

The extraction prompt (`EXTRACTION_RULES`, `main.py:612–802`, ~190 lines) is written specifically around invoice/document extraction correctness, including:
- **Zero-data-loss / row-count self-check** — the model is required to state "Row count: N" before the JSON, so a truncated or short response is visibly wrong even before validation runs.
- **Line-item purity** — a row only belongs in `line_items` if it has its own item code, quantity, or unit price; a subtotal/tax/note/reference row must go in a separately-named field instead (this is exactly what `subtotal_as_line_item` and `empty_line_item` enforce deterministically afterward).
- **Multi-line description joining** — wrapped item descriptions are joined with `/` rather than truncated.
- **Vendor/buyer separation and multi-address handling** — explicit instructions to not conflate the two parties on documents with several printed addresses.
- **Primary invoice-number/date disambiguation** — distinguishing the actual invoice number/date from PO numbers, job numbers, routing numbers, or an approval-email date that also appears on the page.
- **OCR character-confusion awareness** — explicit prompting around commonly-confused OCR characters (`0`/`O`, `1`/`l`/`I`, `5`/`S`, `8`/`B`) so the model treats a suspicious digit as ambiguous rather than confidently wrong.

Measured accuracy on the last 100 real production calls: 0% hard errors, 81% pass every validation check on the first try, 19% flagged (mostly `total_mismatch` and `invoice_number_missing`), most of which the automatic self-correction pass resolves.

### 3.15 Postman setup recap

- Body type: **form-data**, never raw JSON
- `files` key: type must be switched from **Text → File** in Postman's row dropdown
- Don't set `Content-Type` manually — Postman generates the multipart boundary itself
- Limits to respect while testing: ≤20 files, ≤50MB each, `consistency` ≤5

---

## Quick facts

| Item | Value |
|---|---|
| Public base URL | `https://s2f1q59mb9tg9r-7778.proxy.runpod.net` (re-check `/health` after any pod restart) |
| Local base URL | `http://localhost:7778` |
| `/v1/extract` file limits | ≤20 files/request, ≤50MB/file |
| Internal file concurrency | 5 files processed in parallel per request |
| Global LLM concurrency (all endpoints, all keys) | 16 simultaneous generations (`vLLM --max-num-seqs 16`) — the real system-wide ceiling |
| Self-consistency | up to 5 passes per file, majority-vote merged |
| Validation checks | 14 deterministic, code-based (not model-dependent) |

For the rest of the system (RAG, chat presets, auth model, architecture risks) see `/workspace/FULL_DOCUMENTATION.md`.
