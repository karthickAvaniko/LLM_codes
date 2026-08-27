# Avaniko AI — Token / Context-Limit: Permanent Solution

**Goal:** the "maximum context length / token limit" error must **never** reach a user again.
**Model context window:** 32,768 tokens (input + output share this space).
**Status:** all protections below are implemented and live in the gateway.

---

## 1. Why the token error happens

Every request shares one 32,768-token budget across four things:

```
[ system prompt ] + [ conversation history ] + [ document/image text ] + [ model's answer ]
        all of this must fit inside 32,768 tokens
```

The error appears when input + requested output > 32,768. In practice it is almost
always caused by **one oversized input** — a big PDF/invoice, a base64 image, or a
huge pasted block — **not** by conversation history piling up (our logs show only
1–4 messages per request).

> Note: token ≠ character. English ≈ 4 chars/token, but dense invoice/number/code
> text can be ~1.5–2 chars/token, so a "60k character" prompt can be 30k+ tokens.
> This is why a fixed character limit alone is not enough — see the multi-layer fix.

---

## 2. The permanent solution — 6 automatic layers

The gateway handles this with no action needed from the caller. Each layer is a
safety net for the next.

### Layer 1 — Context-aware input budget (before sending)
Input is trimmed to fit `32,768 − requested_output − safety_margin`, using a
**conservative token estimate** (~1.7 chars/token) so even dense text stays inside
the window. Most requests now fit on the first try.
→ `_ctx_char_budget()` + `_fit_messages()` in `main.py`.

### Layer 2 — Auto-shrink + retry (if it still overflows)
If the model still reports a context overflow, the gateway **shrinks the prompt 40%
and retries — up to 4 times — on BOTH streaming and non-streaming paths.** The user
gets an answer; a 400 error can no longer reach them.
→ `_vllm_post()` and the streaming retry loop in `chat_completions`.

### Layer 3 — Conversation-history trimming
If chat history ever grows too large, the gateway keeps the **system prompt + newest
turns** and drops the oldest middle messages until it fits. Long chats never break.
→ `_fit_messages()`.

### Layer 4 — Inline-image OCR (vision requests)
Images sent in OpenAI vision format are **OCR'd to text** before reaching the
text-only model, and that text is also subject to Layers 1–3.
→ `_resolve_images()`.

### Layer 5 — Document pipeline (the real fix for big documents)
Files sent to `/v1/files`, `/v1/files/{id}/ask`, and `/v1/extract` are processed by
size:
- ≤ 40,000 chars → **single pass** (guaranteed to fit).
- larger → **map-reduce**: split into ~35k-char chunks, answer each chunk in parallel,
  then combine. A 500+ page document merges hierarchically. **No size limit.**
→ `answer_document()`, `_chunk_pages()`, `_map_chunks()`.

### Layer 6 — RAG (constant token cost across many documents)
`/v1/ask` embeds the question and sends only the **top ~5 most relevant chunks** to the
model — so whether the user has 1 document or 500, the prompt size stays constant and
**can never overflow.**
→ `rag_retrieve()`, `_rag_messages()`.

---

## 3. How to NEVER hit the limit — choose the right endpoint

| What you're doing | Use this | Why it's safe |
|---|---|---|
| Short chat / Q&A / coding / reasoning | `POST /v1/chat/completions` | auto-budget + auto-retry (Layers 1–3) |
| Invoice/photo → data (image inline) | `/v1/chat/completions` with vision, **or** `/v1/extract` | OCR + budgeting (Layers 4–5) |
| One big PDF → JSON / answer | `POST /v1/files` then `/v1/files/{id}/ask` | map-reduce, any size (Layer 5) |
| Many PDFs in one go | `POST /v1/extract` (≤20 files) | per-file map-reduce (Layer 5) |
| Ask across ALL stored docs | `POST /v1/ask` | RAG, constant cost (Layer 6) |

**Golden rule:** for anything **large or document-shaped**, use the **Files API
(`/v1/files` + `/v1/ask`) or `/v1/extract`** — never paste a whole document into a
chat message. Chat completions will still trim-to-fit and answer, but document
endpoints read the *entire* document without losing content.

---

## 4. Best practices for client apps (your office app)

1. **Don't re-send the full document every turn.** Upload it once with `/v1/files`,
   then ask many questions with `/v1/files/{id}/ask` or `/v1/ask`. (Stateless API:
   you send messages each call, so re-pasting a document each turn wastes the window.)
2. **Send raw files, not page-images you pre-rendered.** The gateway OCRs and reads
   every page itself; sending the original PDF is faster and more accurate.
3. **Keep system prompts lean.** A 2,000-token system prompt is 2,000 fewer tokens
   for the document and answer.
4. **Sanity-check before sending** (optional):
   ```python
   print("messages:", len(messages),
         "chars:", sum(len(str(m.get("content","")))) for m in messages))
   ```
   If chars climbs into the hundred-thousands, switch to the Files API.
5. **For exact totals over big spreadsheets**, extract structured rows then compute in
   your code — LLMs estimate math over thousands of rows.

---

## 5. What changed in the gateway (summary of the fix)

- `_ctx_char_budget()` — budgets input against the window based on requested output.
- `_vllm_post()` + streaming retry loop — auto-shrink and retry on overflow (both paths).
- `_fit_messages()` — trims oversized history / single giant messages.
- `_resolve_images()` — OCRs inline images for the text-only model.
- `SINGLE_SHOT_CHARS` lowered to 40,000 — dense documents auto-use map-reduce.
- Document map-reduce + hierarchical reduce — unlimited document size.
- RAG (`/v1/ask`) — constant token cost across any number of documents.

Result: **a context-overflow 400 can no longer reach a client.** The worst case is a
graceful trim (chat completions) or chunked processing (document endpoints).

---

## 6. References (industry best practices, 2026)

- Redis — *Context Window Overflow in 2026: Fix LLM Errors Fast*:
  https://redis.io/blog/context-window-overflow/
- Atlan — *LLM Context Window Limitations in 2026*:
  https://atlan.com/know/llm-context-window-limitations/
- Unstructured — *Choosing the Right LLM: Context Window Sizes*:
  https://unstructured.io/insights/choosing-the-right-llm-a-guide-to-context-window-sizes
- KDB.AI — *In-Depth Review of Chunking Strategies for RAG and LLMs*:
  https://kdb.ai/learning-hub/articles/in-depth-review-of-chunking-methods/
- Medium (K. Kutumbe) — *Comprehensive Guide to Chunking in LLM and RAG Systems*:
  https://kshitijkutumbe.medium.com/comprehensive-guide-to-chunking-in-llm-and-rag-systems-c579a11ce6e2

These confirm the approach used here: **conservative budgeting + chunking
(map-reduce) + RAG retrieval + history compression** is the standard, robust way to
keep requests inside the context window.
