# Avaniko AI Gateway — Complete Guide

**Public base URL:** `https://s2f1q59mb9tg9r-7778.proxy.runpod.net`

---

## Screens (port 7778)

| Screen | URL | Who |
|---|---|---|
| Chat UI | `/` | public |
| Get API Key (self-service) | `/getkey` | public — name + email → trial key |
| Admin key console | `/keys` | you only (master key) |

**Master admin key:** stored in `/workspace/gateway/.api_key`
```bash
cat /workspace/gateway/.api_key
```

---

## Generate a customer key (terminal)

```bash
curl -X POST http://localhost:7778/admin/keys \
  -H "Authorization: Bearer $(cat /workspace/gateway/.api_key)" \
  -H "Content-Type: application/json" \
  -d '{"name":"customer1","rpm_limit":60,"daily_limit":5000,"expires_days":30}'
```

---

## Using the API key in any application

### Python (OpenAI SDK — pip install openai)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1",
    api_key="ak-your-key-here",
)

resp = client.chat.completions.create(
    model="avaniko-ai",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

### Node.js (npm install openai)

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1",
  apiKey: "ak-your-key-here",
});

const resp = await client.chat.completions.create({
  model: "avaniko-ai",
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(resp.choices[0].message.content);
```

### Plain curl (any language)

```bash
curl https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1/chat/completions \
  -H "Authorization: Bearer ak-your-key-here" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}]}'
```

### PDF / document API (upload once, ask many times)

```python
import requests, time

BASE = "https://s2f1q59mb9tg9r-7778.proxy.runpod.net"
H = {"Authorization": "Bearer ak-your-key-here"}

# 1. upload (PDF/image/txt/csv, max 50 MB — 100+ pages OK)
f = requests.post(f"{BASE}/v1/files", headers=H,
                  files={"file": open("contract.pdf", "rb")}).json()

# 2. wait until extraction ready (scanned PDFs OCR in background)
while requests.get(f"{BASE}/v1/files/{f['id']}", headers=H).json()["status"] == "processing":
    time.sleep(2)

# 3. ask anything
ans = requests.post(f"{BASE}/v1/files/{f['id']}/ask", headers=H,
                    json={"question": "Summarize the payment terms"}).json()
print(ans["answer"])
```

---

## All endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/v1/chat/completions` | POST | OpenAI-compatible chat (streaming supported) |
| `/v1/models` | GET | List models |
| `/v1/usage` | GET | Key holder's own usage |
| `/v1/files` | POST / GET | Upload / list documents. Also imports from URL: `-F "url=https://docs.google.com/spreadsheets/d/..."` (Google Sheets/Drive links auto-converted; sharing must be "Anyone with the link") |
| `/v1/files/{id}` | GET / DELETE | Status / delete |
| `/v1/files/{id}/ask` | POST | Ask question about ONE document (full extraction) |
| `/v1/ask` | POST | **RAG** — ask across ALL your stored documents; `{"question":"...", "stream":true}` for live streaming; returns sources (file + page) |
| `/v1/extract` | POST | **Batch** — up to 10 PDFs in one request → JSON per file |
| `/signup/key` | POST | Public self-service key (currently CLOSED — internal phase) |

**Extras on `/v1/chat/completions`:**
- `"task": "extraction" | "classification" | "coding" | "reasoning" | "chat"` — auto-tuned settings per skill
- `"web_search": true` — gateway searches the web live (DuckDuckGo) and the model answers from the results with [1][2] citations
| `/admin/keys` | POST / GET | Create / list keys (admin only) |
| `/admin/keys/{id}` | DELETE | Revoke key (admin only) |
| `/admin/keys/{id}/enable` | POST | Re-enable key (admin only) |

---

## Limits (measured live on RTX A6000 48GB)

### Per request
- Context window: **32,768 tokens** (input + output)
- Max output: **8,192 tokens** (gateway cap)
- Practical input: ~24,000 tokens ≈ 60,000 characters single-pass;
  bigger documents automatically use map-reduce chunking

### Speed (measured)
- 1 user: 16.4 tok/s (200-token reply ≈ 12 s)
- 8 users parallel: 123 tok/s total, each reply ≈ 13 s
- **8 simultaneous generations** (vLLM max-num-seqs 8); request #9 queues
- Realistic capacity: **50–150 active chat users**, ~10M output tokens/day max

### Per key
| | Self-service trial | Default admin-created |
|---|---|---|
| Requests/minute | 10 | 60 (configurable) |
| Requests/day | 250 | 5,000 (configurable) |
| Expiry | 30 days | optional |
| Files | 200 × 50 MB | 200 × 50 MB |

### Protection built in
- Keys stored SHA-256 hashed (shown only once at creation)
- Brute-force lockout: 20 failed auths/min per IP
- Self-service: 1 active key per email, 2 signups per IP per day
- Instant revoke from `/keys` console
- Token usage tracked per key (billing-ready)

---

## RAG: chat with all your documents (token limit can NEVER overflow)

```python
import requests
BASE = "https://s2f1q59mb9tg9r-7778.proxy.runpod.net"
H = {"Authorization": "Bearer ak-your-key-here"}

# upload any number of PDFs once via POST /v1/files, then:
ans = requests.post(f"{BASE}/v1/ask", headers=H, json={
    "question": "Which vendor invoice has the highest amount?",
}).json()
print(ans["answer"])
print(ans["sources"])   # [{"filename": "...", "page": 3, "score": 0.71}, ...]
```

Only the top 5 most relevant chunks go to the LLM — prompt size stays
constant whether you store 1 PDF or 500 PDFs.

## Batch: multiple PDFs in ONE request

```bash
curl -X POST $BASE/v1/extract \
  -H "Authorization: Bearer ak-your-key" \
  -F "files=@invoice1.pdf" -F "files=@invoice2.pdf" \
  -F "question=Extract invoice_no, total_amount as JSON"
```

## Chatbot token safety

If a chatbot sends a history bigger than the context window, the gateway
automatically keeps the system prompt + newest messages and drops the
oldest — the request succeeds instead of failing with a token error.

---

## Security rule for public apps

Put the API key in your app's **backend / environment variable** —
never in frontend JavaScript or a mobile app binary. Anyone can extract
it from there and burn your GPU quota.

---

## Restart after pod reboot

```bash
bash /workspace/start_all.sh
```
