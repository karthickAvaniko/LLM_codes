# Avaniko AI Gateway — Getting Started

**Goal of this doc:** the two things everyone actually needs first — get a working API key, then have a real conversation with the model. Every request below was run live against the gateway on 2026-08-21 and the shown responses are real, not samples.

---

## Step 1 — Get an API key

There are three possible ways to get a key. Only two currently work.

### ❌ Self-service (`/getkey`) — currently closed

The public signup page exists (`GET /getkey`) and renders a form, but the actual signup call is gated by an environment variable (`AVANIKO_SELF_SIGNUP`) that is **not set** on this deployment. Confirmed live:

```
POST /signup/key
→ {"error":{"message":"Self-service signup is currently closed (internal use only). Contact the administrator for an API key."}}
```

So don't point external users at `/getkey` expecting it to work — it will collect their name/email and then refuse. To open it, an admin would set `AVANIKO_SELF_SIGNUP=1` before starting the gateway (`main.py:1360`).

### ✅ Method A — Admin creates a key from the terminal (fastest)

Anyone with shell access to the pod can mint a key with the master admin key:

```bash
curl -X POST http://localhost:7778/admin/keys \
  -H "Authorization: Bearer $(cat /workspace/gateway/.api_key)" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-app","rpm_limit":60,"daily_limit":5000}'
```

Response (shown once — save it, it can't be retrieved again from the API):
```json
{
  "api_key": "ak-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "id": "ak-xxxxxxxx",
  "name": "postman-test",
  "expires": null,
  "rpm_limit": 60,
  "daily_limit": 5000
}
```

### ✅ Method B — Admin console UI

Open `https://<your-pod-id>-7778.proxy.runpod.net/keys` in a browser, sign in with the admin credentials, and create/revoke/list keys visually. This is the same backend as Method A's key store, just through `/admin-api/keys` instead of `/admin/keys` — either way, the key works identically for API calls.

---

## Step 2 — Have a conversation with the LLM

Endpoint: `POST /v1/chat/completions` (OpenAI-compatible). Auth header on every call:
```
Authorization: Bearer ak-<your-key>
```

### A single message — verified live example

Request:
```bash
curl -X POST http://localhost:7778/v1/chat/completions \
  -H "Authorization: Bearer ak-<your-key>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say OK if you can hear me, one word only."}],"task":"chat"}'
```

Actual response received:
```json
{
  "id": "chatcmpl-b7fc8a9d000fcb60",
  "object": "chat.completion",
  "model": "avaniko-ai",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "OK" },
    "finish_reason": "stop"
  }],
  "usage": { "prompt_tokens": 362, "completion_tokens": 2, "total_tokens": 364 }
}
```

(`prompt_tokens` is 362 rather than a handful of words because the gateway silently injects an identity + date system prompt into every call — see the main reference doc, §4.)

### A real multi-turn conversation

The API is stateless — **the gateway does not remember previous turns for you**. To hold a conversation, your client keeps the running list of messages and resends the whole thing each time, appending the assistant's last reply before the next question:

```python
import requests

BASE = "http://localhost:7778"
KEY  = "ak-<your-key>"
headers = {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"}

conversation = [
    {"role": "user", "content": "My invoice number is INV-4471. Remember that."}
]

r1 = requests.post(f"{BASE}/v1/chat/completions", headers=headers,
                    json={"messages": conversation, "task": "chat"}).json()
reply1 = r1["choices"][0]["message"]["content"]
conversation.append({"role": "assistant", "content": reply1})

conversation.append({"role": "user", "content": "What invoice number did I just give you?"})

r2 = requests.post(f"{BASE}/v1/chat/completions", headers=headers,
                    json={"messages": conversation, "task": "chat"}).json()
print(r2["choices"][0]["message"]["content"])   # → will correctly answer "INV-4471"
```

That's the entire mechanism — "conversation" is just "send the growing message list back every time." If the history gets too large for the model's 32,768-token context window, the gateway automatically trims the oldest messages rather than erroring (see the context-safety section of the main reference doc).

### Streaming a conversation (token-by-token)

Add `"stream": true` and read Server-Sent-Events instead of one JSON blob:

```bash
curl -N -X POST http://localhost:7778/v1/chat/completions \
  -H "Authorization: Bearer ak-<your-key>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Count from 1 to 5."}],"stream":true}'
```

### Postman setup for this endpoint

- Method: `POST`
- URL: `{{base_url}}/v1/chat/completions`
- Headers: `Authorization: Bearer {{customer_key}}`, `Content-Type: application/json`
- Body: **raw → JSON** (not form-data — this endpoint is plain JSON, unlike `/v1/extract`)
```json
{
  "messages": [{"role": "user", "content": "Hello"}],
  "task": "chat",
  "stream": false
}
```

---

## Quick facts you'll need

| Item | Value |
|---|---|
| Public base URL | `https://s2f1q59mb9tg9r-7778.proxy.runpod.net` (re-check `/health` after any pod restart — this URL changes) |
| Local base URL (on-pod) | `http://localhost:7778` |
| Model name to send | `avaniko-ai` (gateway ignores this and always uses its real model, so any value works, but send the real name for clarity) |
| `task` values | `auto` (default) · `chat` · `reasoning` · `coding` · `extraction` · `classification` |
| Max output tokens | capped at 8192 server-side regardless of what you request |
| Context window | 32,768 tokens total (input + output) — history auto-trims if exceeded |

For everything else (file upload, RAG across documents, batch invoice extraction, admin key management, full architecture) see the full reference: `/workspace/FULL_DOCUMENTATION.md`.
