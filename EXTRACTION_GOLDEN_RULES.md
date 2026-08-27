# Extraction Golden Rules & Endpoint Clarity
> Last updated: 2026-08-26 | Source of truth: `gateway/main.py`, `EXTRACTION_RULES` constant (~line 675)

This file is a **readable mirror** of the actual prompt rules baked into the
gateway. If you ever change extraction behavior, change `EXTRACTION_RULES` in
`gateway/main.py` first — then update this file to match. This file is
documentation, not the live source.

---

## Part 1 — Which endpoint does what (the "same or different?" question)

**Short answer: same underlying extraction engine, different API endpoint.**
Not the same route, not a duplicate implementation either — they share the
core building blocks.

| | `POST /v1/extract` | `/chat` (UI) | `POST /files/ask` (UI file-chat) |
|---|---|---|---|
| Who uses it | External API clients, `invoice_to_json.py` | Built-in browser chat UI, plain text messages | Built-in browser chat UI, when a file is attached |
| Purpose | Purpose-built structured JSON extraction API | General chat | Q&A / extraction over an attached document, streamed live |
| Response shape | One JSON response, all files at once | SSE token stream | SSE progress events + streamed token replay |
| Supports `output_schema` (guided decoding) | ✅ | ❌ | ❌ |
| Supports `consistency=N` self-vote | ✅ | ❌ | ❌ |
| Batch multi-file | ✅ (`MAX_BATCH_FILES` per call) | — | ✅ (multiple attachments) |
| Uses `EXTRACTION_RULES` + validation + self-correct | ✅ always | ❌ (plain chat, not extraction) | ✅ **whenever the question implies JSON/extraction** (`_wants_json()`), regardless of document size — otherwise it's a normal free-form answer. *(Until 2026-08-26, validation/self-correction on this endpoint only ran for documents small enough for a single LLM call — a large document forced into map-reduce got no safety net at all, unlike `/v1/extract`. Fixed so both endpoints validate equally regardless of strategy.)* |
| Underlying functions | `answer_document()`, `_vision_doc_messages()`, `_llm_retry_truncation()`, `validate_extraction()`, `_self_correct()` | vLLM chat passthrough | **Same** `_vision_doc_messages()`, `_llm_retry_truncation()`, `validate_extraction()`, `_self_correct()`, `_map_chunks()`/`_reduce_messages()` as `/v1/extract` |
| Queue class (§5 of `CURRENT_ARCHITECTURE.md`) | `DOCUMENT` | `CHAT` | `DOCUMENT` |

**What this means in practice:** if you ask the chatbot UI to extract JSON
from an uploaded file, you get the *same* OCR pipeline, the *same*
vision-hybrid logic, the *same* validation/self-correction safety net, and
the *same* golden rules below as `/v1/extract` — because `/files/ask`
literally calls the same helper functions. What you do NOT get from the UI
is `output_schema` (schema-constrained output) or `consistency` voting —
those are `/v1/extract`-only parameters. **For programmatic/production use,
always use `/v1/extract`** — this is also what `invoice_to_json.py`'s own
docstring says, and it explicitly warns against using `/v1/chat/completions`
with an inline image instead, which "gives inconsistent output call-to-call"
(no OCR fallback, no validation, no self-correction on that path).

---

## Part 2 — The Golden Rules (extraction prompt, verbatim intent)

Only active when the request is JSON/structured extraction (`/v1/extract`
always; `/files/ask` when the question implies JSON). Enforced as `temperature=0.0`
+ a fixed seed (`EXTRACTION_SEED`) — deterministic settings, though see the
note on residual variance at the bottom.

1. **Top-level shape** — always a JSON object `{...}`, never a bare array. Records go in a named array field (e.g. `"line_items": [...]`).
2. **Zero data loss** — extract every row/record. No summarizing or skipping for brevity.
3. **Line-item table purity** — never turn tracking numbers, GL codes, shipping refs, stamps, notes, or email text into a line item. Those go in `metadata`.
4. **Line item validation** — quantity × unit price ≈ amount; a row with description+qty+price+amount all null is never created; never fabricate a value to complete a row; never let the subtotal leak in as a fake row.
4b. **Unit price is read, never computed** *(added 2026-08-27)* — `unit_price` and `amount` are identified by their own column position/header, never inferred from each other. Specifically: never compute `unit_price = amount ÷ quantity` when the source doesn't show a unit price column, or that cell is blank/illegible for a row — leave `unit_price` null instead of backfilling it with a division. A computed value isn't the same as an extracted one.
5. **Flat invoice-level charges vs per-record line items** *(added 2026-08-26)* — a flat charge with no name/identity/locker tied to it (Protection Plus, Delivery Charge, Fuel Surcharge, Service Fee) goes in a separate `additional_charges` field, **never** mixed into `line_items` with per-person/per-unit rows. This was added after a real invoice showed `PROTECTION PLUS` ($180.95) and `DELIVERY CHARGE` ($14.00) merged into the same array as ~80 individual employee garment rows.
6. **Multi-line item descriptions** — wrapped product-spec continuation lines join into one description (joined with `' / '`); administrative annotations (PO/VMI notes, shipping refs) never merge into the description, they go to `metadata`.
7. **Whole-page coverage** — capture letterhead/footer vendor info and header fields (invoice/PO/SO numbers, dates, terms) even though they're outside the table.
8. **Leftover metadata field** — incidental text goes in one `metadata` field, but any real cost-breakdown dollar amount (labor/parts/tax/subtotal/total/balance due) is never swept into it.
9. **Document segmentation for bundled packets** — a scan can contain multiple stapled documents (invoice + PO + inspection report + email thread). Extract fields only from the actually-requested document's own pages.
10. **Vendor/seller AND buyer** are always two separate nested objects (`"vendor"`, `"bill_to"`), never merged.
11. **Multiple addresses for the same entity** — billing vs shipping vs remit-to all kept as separate fields, never overwritten.
12. **Tax rate** — only include a rate field if the document itself prints one; never compute/guess it.
13. **Currency** — infer from a `$`/`€`/`£`/`₹` symbol plus document context; never invent one with zero evidence.
14. **Contextual grouping** — a field belongs with whatever it's physically grouped with on the page, not a generic label guess.
15. **Follow cross-reference pointers, never copy them as the value** *(added 2026-08-26, extended same day)* — some fields are printed as a POINTER to where the real value is, not the value itself (e.g. a `SHIP TO:` field reading "See Address on Lines Below", with the actual address appearing elsewhere on the page, often near the line items under a label like "Primary Location"). Find and extract the real value the pointer refers to; never store the pointer/instruction phrase itself ("See Address on Lines Below", "See Attached", "As Noted Above") as if it were the data. If the real value genuinely can't be found, leave the field out rather than filling it with the pointer text. Added after a real invoice (`INV91679`) came back with `"ship_to": {"note": "See Address on Lines Below"}` — the real ship-to address (`333 Route 17 North, Mahwah NJ 07430`) was sitting right there in the document under "Primary Location," near the line items, and never got extracted. **Extended the same day** to also cover the cross-*page* version of this pattern: a totals/subtotal row showing only "Continued" (or "Cont'd"/"See Next Page") where the number should be, because the real figure is printed on a later continuation page — never store the literal word "Continued" as a total's value, go find the real number on the continuation page instead. Added after a real invoice (`102391`) came back with `"invoice_subtotal": "Continued"` instead of the real `518.00` that was printed on page 3.
16. **Row count preamble** — state `"Row count: N"` on one line before the JSON, and the JSON must contain exactly N entries. *(⚠️ Seen a live case where this preamble said "Row count: 7" but the actual `line_items` array had ~84 entries — a real adherence gap worth watching for, independent of the charges-mixing issue.)*
17. **Column integrity** — a blank cell means null/0 for that row, never shifted into an adjacent column.
18. **Type accuracy** — numeric fields are numbers, never invented; `null` when genuinely absent.
19. **One multi-page invoice vs several separate invoices** *(added 2026-08-26)* — when multiple pages share the same BASE invoice/document number with only a page-position suffix changing (e.g. `10370477-0105`, `-0205`, `-0305` on pages 1-3), and only ONE combined total appears across the whole packet (typically printed once, on the last page), this is **one invoice spanning multiple pages** — return a single top-level object using the shared base number (e.g. `"10370477"`), with every page's rows merged into ONE combined `line_items` array. Never split into an array of N separate invoice objects just because N page-suffixed reference numbers are visible. Never include a forwarding/approval email thread as if it were one of the invoice objects in such an array — it goes in `metadata`, never treated as an invoice itself. Added after a real invoice (5 pages, base number `10370477`, per-page suffixes `-0105` through `-0505`) was seen extracted correctly as one merged invoice on one run, then incorrectly split into 5 fake invoice objects + a 6th fake "invoice" that was actually just the forwarding email, on a repeat run of the identical file.
20. **Primary invoice number** — only the value explicitly labeled "Invoice No."/"Invoice #"/"Invoice Number". PO numbers, internal job/reference numbers, account/GL codes, customer numbers, SO numbers are NEVER substituted for it, even if visually more prominent. If no label exists anywhere, leave `invoice_number` out rather than guessing.
21. **Primary invoice date** — the invoice's own printed date, never an approval/email/routing/statement date from elsewhere in the packet.
22. **Date format** — normalize unambiguous dates to ISO 8601; keep the original string if genuinely ambiguous.
23. **Character accuracy** — cross-check OCR-confusable characters (0/O, 1/l/I, 5/S, 8/B) against context.
24. **Field name must match value shape** — a `website` field must actually look like a URL; a phone number never gets relabeled as `website` just because it was the nearest unlabeled value.
25. **Output purity** — nothing but the `Row count: N` line and the raw JSON object. No markdown fences, no extra commentary.

---

## Part 3 — Known reliability gaps (open, being worked on)

| Gap | Status |
|---|---|
| Charges merged into `line_items` instead of `additional_charges` | ✅ Fixed 2026-08-26 (rule #5 above) |
| Same PDF → different output across separate calls, even at temp=0 + fixed seed | Root cause: GPU batching non-determinism (inherent to vLLM/continuous-batching engines, not a prompt issue). **Mitigation added 2026-08-26:** extraction results are now cached by a hash of (file bytes + question + hints + output_schema + consistency + canonicalize + **the current `EXTRACTION_RULES` text itself**) — same file + same params returns the exact cached JSON on repeat calls instead of re-running inference. Hashing the rules text in means every time the golden rules change, the cache key changes too, so old cached results automatically stop being served instead of silently outliving the prompt fix that was supposed to correct them (this bit us same-day — the first cache implementation didn't include the rules, so the charges-fix and multi-page-invoice fix wouldn't have applied to already-cached files without this). First call for a given file+rules-version is still subject to normal model variance; only *repeats* of an identical request under the same rules are guaranteed identical. Applies to **both** `/v1/extract` and `/files/ask`. See `_extraction_cache_key/_get/_put` in `gateway/main.py` (MySQL table `extraction_cache`). |
| A real multi-page invoice (shared base number + page suffix) got extracted correctly once, then split into 5 fake invoice objects + a fake "invoice" made from the forwarding email, on a repeat run of the identical file | ✅ Fixed 2026-08-26 (rule #18 above) — plus the underlying cause that let it slip through: `/files/ask` wasn't validating/self-correcting map-reduce output at all (see Part 1 table note). Both fixed together. |
| "Row count: N" preamble seen mismatched against actual entry count in at least one real invoice | ✅ Fixed 2026-08-27 — `validate_extraction()` now has an explicit deterministic check (`row_count_mismatch`, not just a prompt rule): it parses the stated "Row count: N" from the raw LLM output and compares it to the actual `line_items` array length, triggering self-correction on any mismatch. Wired into all 3 call sites (`/v1/files/{id}/ask`, `/v1/extract`, `/files/ask`). |
| Unit price sometimes backfilled as `amount ÷ quantity` instead of being read from its own column, when the source doesn't clearly show a unit price | ✅ Fixed 2026-08-27 (rule #4b above) |
| Ship-to address left as `{"note": "See Address on Lines Below"}` instead of following that pointer to the real address printed elsewhere on the page (real invoice `INV91679`) | ✅ Fixed 2026-08-26 (rule #15 above) |
| Flat charges (SHIP row, UPS/Fed-Ex disclaimer) misclassified into `totals` as fake `"description_as_key": 1.0` entries instead of `line_items`/`additional_charges` (real invoice `102391`) | ✅ Confirmed fixed on re-test — same-day rule #5 fix generalizes correctly: SHIP (a genuine row inside the item table, just with no price shown) now lands in `line_items`; the UPS/Fed-Ex disclaimer (no price, no item identity, pure boilerplate) now lands in `additional_charges`. External review of the re-run explicitly preferred this split over forcing both into `line_items`. |
| `"invoice_subtotal": "Continued"` instead of the real total printed on a later continuation page (real invoice `102391`) | ✅ Fixed 2026-08-26 (rule #15 extension above) — was already gone on re-test before the rule was made explicit, but codified so it's guaranteed rather than incidental. |
| Redundant `po_number: null` alongside a correctly-filled `customer_purchase_order` (real invoice `102391`) | Resolved on re-test — the redundant null field no longer appears. Not yet traced to a specific rule; likely a side effect of normal model variance rather than a rule fix. Watch for recurrence. |
