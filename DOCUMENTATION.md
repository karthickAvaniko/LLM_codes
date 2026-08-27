# Avaniko AI Platform — Full Documentation

**Version:** 1.0  **Last updated:** 2026-06-15
**Public base URL:** `https://s2f1q59mb9tg9r-7778.proxy.runpod.net`
**Model name (public):** `avaniko-ai`

---

## 1. Overview

Avaniko AI is a self-hosted, OpenAI-compatible AI platform running on a private
GPU server. It exposes a single API that handles chat, reasoning, coding,
classification, document understanding (PDF/image/Office), web search, and
multi-document RAG — all behind one API key, the same way Gemini and OpenAI work.

Anything that supports a "custom OpenAI base URL" (LangChain, LlamaIndex,
LibreChat, n8n, etc.) works with zero code changes — just set the base URL and key.

---

## 2. Authentication

Every request (except UI pages and `/health`) needs an API key:

```
Authorization: Bearer ak-xxxxxxxxxxxxxxxxxxxxxxxx
```

- Keys are created in the Developer Console (`/console`) or Admin Console (`/keys`).
- Keys are stored as SHA-256 hashes — the raw key is shown **once** at creation.
- Each key has limits: requests/minute, requests/day, optional expiry.
- Invalid/expired key → `401`. Over rate limit → `429`. 20 failed auths/min per IP → temporary block.

---

## 3. Getting an API key

### Option A — Developer Console (self-service, recommended)
1. Open `https://s2f1q59mb9tg9r-7778.proxy.runpod.net/console`
2. Register with an **@avaniko.com** email + password (only avaniko.com allowed).
3. Log in → "Create API key" → copy it immediately (shown once).
4. Each user can hold up to 3 active keys, and sees their own usage.

### Option B — Admin Console (for the administrator)
1. Open `/keys`, unlock with the master admin key (`/workspace/gateway/.api_key`).
2. Create a key with any name, rpm/daily limits, and expiry.

### Option C — Terminal
```bash
curl -X POST http://localhost:7778/admin/keys \
  -H "Authorization: Bearer $(cat /workspace/gateway/.api_key)" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-app","rpm_limit":120,"daily_limit":20000}'
```

---

## 4. Endpoints

### 4.1 Chat / reasoning / coding — `POST /v1/chat/completions`
OpenAI-compatible. Streaming supported (`"stream": true`).

```bash
curl https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1/chat/completions \
  -H "Authorization: Bearer ak-your-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"avaniko-ai","messages":[{"role":"user","content":"Hello"}]}'
```

**Optional fields:**
| Field | Values | Meaning |
|---|---|---|
| `task` | `auto` (default), `chat`, `reasoning`, `coding`, `extraction`, `classification` | Auto-tunes temperature + thinking mode. `auto` = model decides. |
| `web_search` | `auto` (default), `true`, `false` | `auto` = model decides if live info is needed. |
| `stream` | `true`/`false` | Token streaming. |
| `temperature`, `max_tokens` | numbers | Standard OpenAI params (always respected). |

Notes:
- Context window: 32,768 tokens. Max output: 8,192 tokens.
- Over-long chat history is auto-trimmed (keeps system + newest turns) — never errors.

### 4.2 List models — `GET /v1/models`
Returns `avaniko-ai`.

### 4.3 Own usage — `GET /v1/usage`
Returns the calling key's requests, tokens in/out, limits, last used.

### 4.4 Files API (upload once, ask many times)
| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/files` | Upload a file (multipart `file=@...`) OR import a URL (`url=...`, Google Sheets/Drive supported). Returns a `file-...` id; processing runs in background. |
| `GET` | `/v1/files` | List your files. |
| `GET` | `/v1/files/{id}` | Status — poll until `"status":"ready"`. |
| `DELETE` | `/v1/files/{id}` | Delete. |
| `POST` | `/v1/files/{id}/ask` | Ask a question about one file: `{"question":"..."}`. |

Supported types: pdf, png, jpg, jpeg, webp, bmp, tiff, txt, csv, md, json, html, docx, xlsx, xls. Max 50 MB/file, 200 files per key.

```python
import requests, time
BASE="https://s2f1q59mb9tg9r-7778.proxy.runpod.net"
H={"Authorization":"Bearer ak-your-key"}
f = requests.post(f"{BASE}/v1/files", headers=H,
                  files={"file": open("contract.pdf","rb")}).json()
while requests.get(f"{BASE}/v1/files/{f['id']}", headers=H).json()["status"]=="processing":
    time.sleep(2)
print(requests.post(f"{BASE}/v1/files/{f['id']}/ask", headers=H,
      json={"question":"Summarize the payment terms"}).json()["answer"])
```

### 4.5 Batch extract — `POST /v1/extract`
Up to 20 files in one request → one result per file. Synchronous.

```python
import requests
files = [
  ("files", ("inv1.pdf", open("inv1.pdf","rb"))),
  ("files", ("inv2.pdf", open("inv2.pdf","rb"))),
]
r = requests.post(f"{BASE}/v1/extract", headers=H, files=files,
    data={"question":"Extract invoice_no and total as JSON"}).json()
for res in r["results"]:
    print(res["filename"], "->", res.get("answer", res.get("error")))
```
> IMPORTANT: send files as a **list of tuples** (repeat the `files` field).
> A Python dict `{"files":a,"files":b}` keeps only the last file.

### 4.6 RAG — ask across ALL your documents — `POST /v1/ask`
Upload many files via `/v1/files`, then ask one question across all of them.
Only the most relevant chunks go to the model, so the token limit can never overflow.

```python
ans = requests.post(f"{BASE}/v1/ask", headers=H,
      json={"question":"Which invoice has the highest amount?"}).json()
print(ans["answer"])
print(ans["sources"])   # [{filename, page, score}, ...]
```

---

## 5. Output format behaviour

The document endpoints reply in the format you ask for:
- "analyse / explain / summarize / describe" → plain language (prose).
- "extract ... as JSON" / "structured data" → JSON.

For invoice→JSON accuracy, use a compact schema (only the fields you need) — it is
faster and more reliable than "extract everything".

---

## 6. Using from any language

### Python (OpenAI SDK)
```python
from openai import OpenAI
client = OpenAI(base_url=f"{BASE}/v1", api_key="ak-your-key")
r = client.chat.completions.create(model="avaniko-ai",
    messages=[{"role":"user","content":"Hi"}])
```

### Node.js
```javascript
import OpenAI from "openai";
const client = new OpenAI({ baseURL: `${BASE}/v1`, apiKey: "ak-your-key" });
const r = await client.chat.completions.create({
  model: "avaniko-ai", messages: [{role:"user", content:"Hi"}] });
```

### curl / any HTTP client
Use `Authorization: Bearer ak-...` against the endpoints above.

---

## 7. Limits & capacity

| Item | Value |
|---|---|
| Context window | 32,768 tokens (8,192 max output) |
| Concurrent generations | 8 (extra requests queue, never fail) |
| Throughput | ~73 tok/s single, ~418 tok/s at 8 parallel |
| Invoice extraction | 5–8 s per document |
| Self-service trial key | 10 rpm / 250 per day / 30-day expiry |
| Default admin key | 60 rpm / 5,000 per day (configurable) |
| File | 50 MB, 200 per key |

---

## 8. Errors

All errors return clean JSON: `{"error":{"message":"...","type":"..."}}`.

| Code | Meaning |
|---|---|
| 400 | Bad request (missing field, too many files) |
| 401 | Invalid/missing/expired API key |
| 403 | Admin-only endpoint with a non-admin key |
| 409 | File still processing |
| 413 | File too large |
| 429 | Rate limit / daily quota exceeded |
| 422 | Document unreadable / too dense |
| 502/500 | Backend issue (logged server-side) |

---

## 9. Security best practices

- Keep API keys in backend / environment variables — never in frontend JS or mobile binaries.
- One key per app, so you can revoke/track each independently.
- Rotate keys periodically; revoke unused ones from the console.

---

## 10. Screens

| URL | Audience | Purpose |
|---|---|---|
| `/` | anyone (needs key in UI) | Chat UI — files, screenshot paste, web search, history |
| `/console` | @avaniko.com users | Self-service keys + usage |
| `/keys` | administrator | Manage all keys |

---

## 11. Administration quick reference

```bash
# master admin key
cat /workspace/gateway/.api_key
# all keys / usage (SQL)
mysql avaniko -e "SELECT name,email,requests,tokens_in,tokens_out,active FROM api_keys;"
# users
mysql avaniko -e "SELECT email,name,created FROM users;"
# restart everything (after pod reboot)
bash /workspace/start_all.sh
# health
curl http://localhost:7778/health
```
