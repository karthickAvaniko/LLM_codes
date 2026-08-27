# Avaniko AI Platform — முழு Project Report (A to Z)

**Date:** 2026-06-12 | **Owner:** surya.inbasagaran@avaniko.com

---

## 1. Project என்ன?

நம்ம சொந்த AI platform — Gemini / Claude API மாதிரி. நம்ம own GPU server-ல
LLM model ஓடுது. Users-க்கு **API key** கொடுக்கறோம் — அந்த key வச்சு அவங்க
chat, coding, reasoning, PDF reading, invoice extraction எல்லாம் பண்ணலாம்.

**Public URL:** `https://s2f1q59mb9tg9r-7778.proxy.runpod.net`
**Model பெயர் (public):** `avaniko-ai` — உள்ள என்ன model ஓடுதுன்னு
customer-க்கு தெரியாது (white-label).

---

## 2. RunPod-ல என்ன ஓடுது? (Architecture)

RunPod = நம்ம GPU server (RTX A6000 48GB, 9 CPU cores, 503GB RAM).
அதுல 5 services ஓடுது:

```
Internet (customer / office app)
        │
        ▼
RunPod Proxy (https://s2f1q59mb9tg9r-7778.proxy.runpod.net)
        │
        ▼
┌─────────────────────────── RunPod Pod ───────────────────────────┐
│                                                                  │
│  ① Gateway (port 7778) ← இது மட்டும் தான் public                  │
│     - API key check, rate limit, logging                         │
│     - chat UI, console UI, document pipeline                     │
│         │                                                        │
│         ├──► ② vLLM (port 7777, localhost மட்டும்)                │
│         │       Qwen3.6-35B model — GPU-ல text generate          │
│         │                                                        │
│         ├──► ③ Embedding service (port 7779, localhost)          │
│         │       RAG search-க்கு (MiniLM model, CPU)               │
│         │                                                        │
│         └──► ④ MySQL (port 3306, localhost)                      │
│                 api_keys, users, sessions tables                 │
│                                                                  │
│  ⑤ Backup loop — தினமும் /workspace/backups-ல tar.gz             │
└──────────────────────────────────────────────────────────────────┘
```

**முக்கியம்:** vLLM, MySQL, Embedding எல்லாம் localhost-ல மட்டும் —
வெளில இருந்து யாரும் தொட முடியாது. Gateway வழியா மட்டும் தான் access.

Pod restart ஆனா எல்லாத்தையும் start பண்ண:
```bash
bash /workspace/start_all.sh
```

---

## 3. API Key எப்படி வேலை செய்யுது? (A to Z)

### Key உருவாக்கம் (3 வழி)

1. **Developer Console** (`/console`) — team members @avaniko.com email-ல
   register பண்ணி, login பண்ணி, தங்களோட key-ஐ தாங்களே create பண்ணலாம்
   (ஒருத்தருக்கு max 3 keys).
2. **Admin Console** (`/keys`) — நீங்க (master key வச்சு) எந்த
   பெயர்/limit-லயும் key create பண்ணலாம்.
3. **Terminal** — curl மூலமா `/admin/keys` POST.

### Key பாதுகாப்பு (இது தான் core)

- Key format: `ak-` + 48 hex characters (உதாரணம்: `ak-8451642...`)
- **Server-ல raw key எங்கேயும் சேமிக்கப்படாது!** SHA-256 hash மட்டும்
  MySQL-ல இருக்கும். அதனால DB leak ஆனாலும் key திருட முடியாது.
- Key create பண்ணும்போது **ஒரே ஒரு முறை** மட்டும் காட்டப்படும் —
  அப்பவே copy பண்ணணும்.
- ஒவ்வொரு key-க்கும்: rpm_limit (நிமிஷத்துக்கு requests),
  daily_limit (நாளுக்கு), expiry date (optional), usage counters.

### ஒரு request வரும்போது என்ன நடக்குது? (step by step)

```
1. Customer app அனுப்புது:
   POST https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1/chat/completions
   Header: Authorization: Bearer ak-xxxxx...

2. RunPod proxy → Gateway port 7778-க்கு forward

3. Gateway middleware:
   a. Header-ல இருந்து key-ஐ எடுக்கும்
   b. SHA-256 hash பண்ணி memory cache-ல தேடும் (MySQL backup)
   c. Key இல்லை / தப்பு → 401 error
      (ஒரே IP 20 முறை தப்பா try பண்ணா → 1 நிமிஷம் block)
   d. Key expire ஆகிடுச்சா → 401
   e. Rate limit தாண்டிடுச்சா (உதா: நிமிஷத்துக்கு 60) → 429 error
   f. எல்லாம் சரி → requests count +1, last_used update

4. Gateway → vLLM (localhost:7777) → GPU-ல answer generate

5. Response-ல "model": "avaniko-ai" stamp பண்ணி customer-க்கு திருப்பி

6. Token usage (input/output) அந்த key-ல record ஆகும் — billing ready

7. எல்லா request-um logs-ல: access.jsonl (யார், எப்போ, status, time)
```

### Key revoke

Console-ல "Revoke" button → அடுத்த request-லயே 401. Instant.

---

## 4. Customer எப்படி use பண்ணுவாங்க?

### Python (OpenAI SDK — Gemini/OpenAI மாதிரியே)

```python
from openai import OpenAI
client = OpenAI(
    base_url="https://s2f1q59mb9tg9r-7778.proxy.runpod.net/v1",
    api_key="ak-their-key",
)
r = client.chat.completions.create(
    model="avaniko-ai",
    messages=[{"role": "user", "content": "Hello"}],
)
```

### முக்கிய endpoints

| Endpoint | வேலை |
|---|---|
| `POST /v1/chat/completions` | Chat / coding / reasoning (streaming உண்டு) |
| `POST /v1/extract` | 20 PDF/image வரை ஒரே request-ல → ஒவ்வொன்னுக்கும் JSON |
| `POST /v1/files` | Document upload (50MB, key-க்கு 200 files). Google Sheets/Drive URL-ம் ஏத்துக்கும் |
| `POST /v1/files/{id}/ask` | ஒரு document பத்தி கேள்வி |
| `POST /v1/ask` | **RAG** — store பண்ண எல்லா documents-லயும் ஒரே கேள்வி (sources உடன்) |
| `GET /v1/usage` | அந்த key-ஓட சொந்த usage |

### Special features (chat completions-ல)

- `"task": "extraction" / "coding" / "reasoning" / "classification" / "chat"`
  → அந்த வேலைக்கு ஏத்த settings auto-ஆ set ஆகும்
- `"web_search": true` → live internet search பண்ணி அதை வச்சு answer
  ([1][2] citations உடன்)

---

## 5. Document Pipeline (PDF → answer எப்படி?)

```
PDF/image/docx/xlsx வருது
   │
   ├─ Digital PDF (text layer இருந்தா) → நேரடியா text read (வேகம், 100% accurate)
   ├─ Scanned PDF / image → OCR (2 engine pool, rotation/unwarp auto-fix,
   │                          crash ஆனா auto-retry)
   ├─ Word (.docx) → paragraphs + tables read
   └─ Excel/Sheets → எல்லா sheets-um CSV-ஆ read
   │
   ▼
சின்ன document (≤60,000 chars) → ஒரே LLM call (single_pass)
பெரிய document → 35,000-char chunks-ஆ பிரிச்சு parallel-ஆ analyze
                 (map_reduce) → 500+ பக்கம் ஆனாலும் hierarchical-ஆ merge
   │
   ▼
Answer (streaming — பெரிய scanned file-னாலும் "⏳ Reading documents…"
progress காட்டும், timeout ஆகாது)
```

RAG (`/v1/ask`): ஒவ்வொரு document-um upload ஆனவுடனே chunks-ஆ பிரிச்சு
embedding vectors-ஆ index ஆகும். கேள்வி கேட்டா top-5 relevant chunks
மட்டும் LLM-க்கு போகும் — அதனால **எத்தனை PDF இருந்தாலும் token limit
வராது**.

---

## 6. Speed & Capacity (நேரடியா அளந்தது)

| அளவீடு | மதிப்பு |
|---|---|
| Generation speed (1 user) | ~73 tokens/sec |
| 8 users ஒரே நேரம் | 418 tok/s மொத்தம், ஒவ்வொருத்தரும் ~3.8s wait |
| Invoice extraction (image, OCR உடன்) | 5–8 விநாடி |
| 12 digital PDFs ஒரே request | 4.3 விநாடி (எல்லாம் success) |
| Context window | 32,768 tokens (output max 8,192) |
| ஒரே நேரம் parallel generations | 8 (மீதி queue — fail ஆகாது) |
| நாள் முழு capacity | ~36 million output tokens |
| Active chat users தாங்கும் | ~200–400 பேர் |

---

## 7. Storage & Data (MySQL)

| Table | என்ன இருக்கு |
|---|---|
| `api_keys` | key hash, பெயர், email, limits, requests, tokens in/out, last_used |
| `users` | console accounts (@avaniko.com மட்டும், password PBKDF2 hash) |
| `sessions` | login sessions (7 நாள் validity, hash-ஆ சேமிப்பு) |

பார்க்க: `mysql avaniko` → `SELECT * FROM api_keys;`
Data location: `/workspace/mysql` (pod restart ஆனாலும் அழியாது)

**Backups:** தினமும் auto — keys DB dump + customer files + code எல்லாம்
`/workspace/backups/avaniko_YYYY-MM-DD.tar.gz` (14 நாள் வைக்கும்).

**Logs:** `/workspace/logs/`
- `access.jsonl` — ஒவ்வொரு request (IP, key, status, நேரம்)
- `requests.jsonl` — content previews (1000 chars மட்டும் — privacy)
- `gateway_app.log` — errors / OCR / system info

---

## 8. Security (production-level)

✅ Keys SHA-256 hash மட்டும் (raw key சேமிப்பில்லை)
✅ vLLM port 7777 public-ல **மூடப்பட்டது** (முன்னாடி திறந்திருந்தது — பெரிய hole, fix ஆச்சு)
✅ Brute-force block: 20 fail/நிமிஷம் per IP
✅ Rate limit + daily quota ஒவ்வொரு key-க்கும்
✅ Public self-signup **closed** (internal phase) — திறக்க: `AVANIKO_SELF_SIGNUP=1`
✅ Console: @avaniko.com email மட்டும் register
✅ ஒரு user இன்னொருத்தரோட key-ஐ பார்க்கவோ revoke பண்ணவோ முடியாது
✅ Error வந்தா raw crash இல்லை — clean JSON error + log-ல full traceback

---

## 9. Screens (UI)

| URL | யாருக்கு | என்ன |
|---|---|---|
| `/` | எல்லாரும் (key வேணும்) | Chat UI — files attach (20 வரை), screenshot paste, web search 🌐, code copy button |
| `/console` | Team (@avaniko.com login) | சொந்த API keys create/revoke, usage stats, quickstart |
| `/keys` | நீங்க மட்டும் (master key) | எல்லா keys-um manage, email உடன், limits set |

Master admin key: `cat /workspace/gateway/.api_key`

---

## 10. அடுத்து என்ன? (என் பரிந்துரை)

1. **Team-ஐ /console-ல register பண்ண சொல்லுங்க** — இன்னும் யாரும் account
   create பண்ணலை (0 users). Platform ready, பயன்படுத்தணும்.
2. **Office app-ல multi-file bug fix** — server 12 files ஏத்துக்குது;
   உங்க app code-ல dict format தப்பு (list of tuples-ஆ மாத்தணும்).
3. **GPU OCR** — scanned documents அதிகம்னா 5–10x வேகம் (கவனமா செய்யணும், VRAM check உடன்).
4. **Offsite backup** — pod delete ஆனா data காப்பாத்த வெளி storage (S3/Drive).
5. **Custom domain** — `api.avaniko.com` (pod மாறினாலும் URL மாறாது).
6. **Payment gateway** — customer phase வரும்போது மட்டும்.
