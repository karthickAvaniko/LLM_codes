# PDF Invoice Through `/files/ask` — API Call vs. Chatbot Prompt

> Plain-language answer to: "the `/files/ask` endpoint handles a PDF invoice
> and the API call works — so why does the chatbot behave differently /
> not run the extraction prompt the same way?"

**Short answer:** it's the same endpoint and the same engine underneath —
`/files/ask` (`gateway/main.py:3608`). The chatbot UI (`gateway/static/index.html`)
just calls it with a **different default question**, and that one detail
changes which prompt actually runs. Details below.

---

## 1. It's one endpoint, two ways to call it

| | Calling `/files/ask` directly (API) | Dragging a PDF into the chatbot UI |
|---|---|---|
| Endpoint hit | `POST /files/ask` | `POST /files/ask` (same one) |
| Question sent | Whatever you put in `question=` | Whatever you typed, **or**, if you typed nothing: `"Describe the content of this file in detail. If it is a document (invoice, statement, form), summarize the key information in plain language."` (`gateway/static/index.html:647`) |
| Files field | `files=` (multipart) | Same, built automatically from the attached file (`index.html:645-646`) |

So "the chatbot" isn't a separate code path with its own broken prompt —
it's the exact same `/files/ask` call, just with the browser filling in a
default question for you when the message box is left empty.

---

## 2. Why that one detail matters: `_wants_json()`

Inside `/files/ask`, the system prompt — and whether validation/self-correction
run at all — depends on one check (`gateway/main.py:986`):

```python
def _wants_json(question: str) -> bool:
    q = (question or "").lower()
    return any(k in q for k in ("json", "structured data", "schema"))
```

This literally looks for the words **"json"**, **"structured data"**, or
**"schema"** somewhere in the question text. That single check decides two
things at once:

- **Which system prompt is built** (`gateway/main.py:1162`, `:1175`):
  `DOC_SYSTEM + (EXTRACTION_RULES if _wants_json(question) else "")`
  — the ~190-line invoice extraction rulebook (`EXTRACTION_GOLDEN_RULES.md`)
  only gets attached when the question passes this check.
- **Whether the deterministic double-check + self-correction pass runs**
  (`gateway/main.py:3778`, `:2018`) — again, gated on the same
  `_wants_json(question)`.

**The default chatbot question — `"Describe the content of this file in
detail..."` — does NOT contain any of those three words.** So when someone
just drops an invoice PDF into the chat and hits send with no text typed:

- it does **not** get `EXTRACTION_RULES` attached,
- it does **not** get `validate_extraction()` / self-correction,
- it gets a **plain-language summary**, streamed token-by-token like normal
  chat — not a JSON invoice object.

This is almost certainly what "the chatbot prompt doesn't run [the extraction]"
means in practice: the extraction prompt genuinely never fires unless the
question itself asks for JSON/structured data.

**Fix, from the chat UI:** type something like *"Extract this invoice as
JSON"* or *"Give me structured data for this invoice"* in the message box
before sending the file — any of the three trigger words is enough. Calling
the API directly with `question="Extract all information as JSON"` (the
endpoint's own default when called via `curl`/Postman with no `question`
field — `gateway/main.py:3613`) always takes the extraction path, which is
why the direct API call "just works" while an empty-message chatbot drop
doesn't.

---

## 3. What happens once the extraction path IS taken

Once a question does contain a trigger word, `/files/ask` runs the same
pipeline `/v1/extract` uses (full step-by-step version in
`PDF_TO_JSON_WORKFLOW.md`):

```
Upload received
   → extract_pages() — native PDF text, OCR fallback for scanned pages
   → small enough (≤ 80,000 chars, single file)?
        yes → attach real page images too (vision-hybrid) if ≤10 pages
        no  → split into chunks, extract each in parallel, merge (map-reduce)
   → one non-streaming LLM call (temp 0, seed fixed) with
     DOC_SYSTEM + EXTRACTION_RULES as the system prompt
   → validate_extraction() — 14 deterministic checks (row math, totals,
     duplicate rows, missing header fields, ...)
   → if something fails: one self-correction LLM call, told exactly
     what's wrong, then re-checked
   → final JSON "replayed" to the browser as fake typing events (60 chars
     at a time) so it still looks like live streaming, even though the
     validated answer was already fully computed server-side first
```

Non-JSON questions (the default chatbot case, or any plain "summarize this
for me") skip validation entirely and stream the real LLM tokens live,
because there's nothing to validate a prose answer against.

---

## 4. One more chatbot-specific gap worth knowing

`/files/ask` builds its system prompt from `DOC_SYSTEM` only — it never
includes `IDENTITY_PROMPT` (the "you are Avaniko AI" branding block that
plain `/chat` always prepends). So a file-attached chat turn won't answer
"who made you?" with the branded identity — that instruction simply isn't
present on this code path. Cosmetic, not functional, but easy to mistake
for "the chatbot isn't running my prompt right."

Also worth knowing: each `/files/ask` call is a **one-shot** request — the
chatbot UI does not add the file's extracted content or the answer back
into the ongoing `messages` conversation history (`index.html:643-653`).
A follow-up question typed after the file result goes to plain `/chat`
with no memory of the file at all, so it must reference the invoice again
by re-attaching it, not by asking a bare follow-up question.

---

## 5. Quick checklist if a PDF invoice "isn't extracting" in the chatbot

1. Did the typed question contain "json", "structured data", or "schema"?
   If not, you got a prose summary by design — not a bug.
2. Is the file one of the allowed types (`.pdf .png .jpg .jpeg .webp .txt
   .csv .xlsx .docx`) and under the size cap? Check `GET /v1/files` /
   the upload response for `status: "error"`.
3. Large multi-page scanned PDFs can take a while — the UI shows
   `"Reading documents… (Ns)"` / `"Analyzing N sections…"` heartbeats
   while OCR/map-reduce runs; that's normal progress, not a stall.
4. Asking a second question about the same file? Re-attach it — the
   chatbot doesn't carry file content into later turns (see §4).

---

*Related docs: `PDF_TO_JSON_WORKFLOW.md` (full extraction pipeline),
`CHATBOT_FILE_TO_JSON_REPORT.md` (system prompts verbatim + streaming
mechanics), `DIRECT_API_VS_CHATBOT_ACCURACY_REPORT.md` (accuracy
differences when a document is split client-side vs. sent whole).*
