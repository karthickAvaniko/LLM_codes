# Avaniko AI Platform
## Business Capability & Projection Report

**Prepared by:** Avaniko Technologies  
**Date:** June 2026  
**Version:** 1.0  
**Confidential**

---

## Executive Summary

Avaniko AI Platform is a **production-grade, private AI API** built on the Qwen3.6-35B language model. It provides a complete, OpenAI-compatible AI infrastructure that businesses can use immediately — for chat, document processing, data extraction, reasoning, code generation, and more.

The platform is **fully self-hosted on RunPod GPU infrastructure**, meaning all data stays private, there are no per-token costs to OpenAI or Google, and the API can be white-labeled and sold to clients under any brand name.

---

## 1. What the Platform Can Do

### 1.1 All Supported Use Cases

The platform is **not limited to one use case**. A single API key gives access to all capabilities below:

---

### USE CASE 1 — General Chat & Customer Support

**What it does:**  
Conversational AI for any industry. Remembers session history. Supports multi-turn dialogue.

**Example:**
```
User:  What are your refund policies?
AI:    Based on your policy document, refunds are accepted within 30 days...
```

**Who uses this:**
- Customer support automation
- Internal helpdesk bots
- HR FAQ bots
- Website chat widgets

**API Call:**
```http
POST /v1/chat/completions
x-api-key: sk-ava-xxxx

{
  "model": "avaniko-1",
  "messages": [{"role": "user", "content": "What is your return policy?"}]
}
```

---

### USE CASE 2 — Document Q&A (RAG)

**What it does:**  
Upload any PDF, Word, Excel file. Ask questions. AI reads the document and answers accurately. Handles documents of any size using smart map-reduce pipeline.

**Example:**
```
Upload: Company_Annual_Report_2025.pdf (120 pages)
Question: What was the revenue in Q3?
Answer: Q3 revenue was ₹4.2 Cr, up 18% from Q2 per page 34...
```

**Supported file types:**
| Type | Extension | Works |
|------|-----------|-------|
| PDF | .pdf | ✅ |
| Excel | .xlsx, .xls | ✅ |
| Word | .docx | ✅ |
| Images | .jpg, .png | ✅ (OCR) |
| CSV | .csv | ✅ |
| Text | .txt, .json, .xml | ✅ |

**Who uses this:**
- Legal document review
- Financial report analysis
- Policy & compliance Q&A
- Research & knowledge base

---

### USE CASE 3 — Invoice / Document to JSON (Data Extraction)

**What it does:**  
Upload any invoice, receipt, ID card, contract, resume — AI extracts all fields and returns clean structured JSON. Works with any format, any country, any layout.

**Example Input:** Any invoice image or PDF  
**Example Output:**
```json
{
  "invoice_number": "INV-2024-0892",
  "date": "2024-03-15",
  "vendor": {
    "name": "Tech Supplies Pvt Ltd",
    "gstin": "29ABCDE1234F1Z5",
    "address": "Mumbai, Maharashtra"
  },
  "bill_to": {
    "name": "Avaniko Technologies",
    "address": "Chennai, Tamil Nadu"
  },
  "line_items": [
    { "description": "Laptop Dell XPS 15", "qty": 2, "rate": 85000, "amount": 170000 },
    { "description": "Wireless Mouse", "qty": 5, "rate": 1200, "amount": 6000 }
  ],
  "subtotal": 176000,
  "cgst": 15840,
  "sgst": 15840,
  "total": 207680,
  "payment_terms": "Net 30"
}
```

**Document types supported:**
| Document | Output |
|----------|--------|
| Invoice (Indian/US/EU) | JSON with all fields |
| Receipt | Store, items, total, tax |
| ID Card / Aadhaar / PAN | Name, DOB, ID number |
| Contract | Parties, dates, clauses |
| Resume / CV | Skills, experience, education |
| Bank Statement | Transactions, balance |
| Any custom document | Auto-detect all fields |

**Who uses this:**
- Accounting & ERP automation
- Expense management tools
- KYC / onboarding workflows
- Logistics & procurement

---

### USE CASE 4 — Reasoning & Analysis

**What it does:**  
Deep analytical thinking. The model works through complex problems step-by-step, showing its reasoning chain. Useful for financial analysis, legal analysis, risk assessment.

**Example:**
```
Question: Analyse the cash flow risk in this business plan
Answer:   [Step 1] Revenue projections show 40% growth assumption...
          [Step 2] Fixed costs represent 65% of projected revenue...
          [Step 3] Break-even is at Month 8, but...
          Conclusion: HIGH RISK — 3 critical vulnerabilities identified...
```

**Who uses this:**
- Business analysts
- Financial advisors
- Risk assessment teams
- Research teams

---

### USE CASE 5 — Code Generation & Review

**What it does:**  
Write, debug, explain, and review code in any programming language. Generates working code from plain English descriptions.

**Example:**
```
Request: Write a Python script to read invoices from a folder,
         extract totals using this API, and save to Excel
Output:  [Complete working Python script, 80 lines]
```

**Who uses this:**
- Development teams
- No-code/low-code builders
- IT support automation

---

### USE CASE 6 — OCR (Image & Scanned PDF to Text)

**What it does:**  
Extract text from photos of documents, scanned PDFs, handwritten notes, screenshots. Uses PaddleOCR + AI for maximum accuracy.

**Who uses this:**
- Document digitization
- Insurance claim processing
- Government form processing

---

### USE CASE 7 — Custom AI Projects (White-label)

**What it does:**  
Create a custom AI "project" with a specific system prompt. Each project behaves like a completely different AI product.

**Example projects you can create:**
```
Project 1: "Invoice Extractor for Client A"
           → Only extracts invoices, returns JSON, nothing else

Project 2: "HR Chatbot for Company B"
           → Only answers HR questions from uploaded policy docs

Project 3: "Legal Document Reviewer for Firm C"
           → Analyses contracts, flags risk clauses

Project 4: "Customer Support Bot for E-commerce D"
           → Handles returns, orders, complaints
```

**This means:** One platform → sell multiple AI products to multiple clients.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    CLIENT / END USER                          │
│         Web App  |  Mobile App  |  ERP System  |  API Call   │
└──────────────────────────┬───────────────────────────────────┘
                           │  HTTPS
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                  AVANIKO PLATFORM (IIS / VPS)                 │
│                                                              │
│  ┌─────────────┐   ┌──────────────┐   ┌──────────────────┐  │
│  │  React      │   │   FastAPI    │   │   PostgreSQL     │  │
│  │  Dashboard  │   │   Backend    │   │   + pgvector     │  │
│  │             │   │              │   │                  │  │
│  │  API Keys   │   │  Auth (JWT)  │   │  Users, Keys,    │  │
│  │  Usage      │   │  Rate Limit  │   │  Billing, Logs   │  │
│  │  Projects   │   │  Billing     │   │                  │  │
│  └─────────────┘   └──────┬───────┘   └──────────────────┘  │
└─────────────────────────── │ ─────────────────────────────────┘
                             │  Private (URL hidden from clients)
                             ▼
┌──────────────────────────────────────────────────────────────┐
│                  AI BACKEND (RunPod GPU)                      │
│                                                              │
│  Port 2222  ┌─────────────────────────────────────────────┐  │
│  Gateway    │  FastAPI  →  Smart Router                    │  │
│             │                                             │  │
│             │  < 4K tokens  →  Direct LLM call            │  │
│             │  4K–100K      →  Parallel Map-Reduce        │  │
│             │  > 100K       →  RAG (ChromaDB vector)      │  │
│             └───────────────────┬─────────────────────────┘  │
│                                 │                             │
│  Port 1111  ┌───────────────────▼─────────────────────────┐  │
│  vLLM       │  Qwen3.6-35B-A3B (GPTQ Int4)                │  │
│             │  Max context: 16,384 tokens                  │  │
│             │  GPU: RunPod A100/A6000                      │  │
│             └─────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Technical Specifications

| Property | Value |
|----------|-------|
| AI Model | Qwen3.6-35B-A3B-GPTQ-Int4 |
| Model Type | Mixture of Experts (MoE) — 35B total, 3.6B active |
| Max Context | 16,384 tokens (~12,000 words) |
| Inference Engine | vLLM (optimized GPU serving) |
| API Compatibility | OpenAI API (drop-in replacement) |
| Gateway | FastAPI (Python) |
| Database | MySQL (gateway) + PostgreSQL (platform) |
| Vector DB | ChromaDB (RAG storage) |
| Auth | API Keys + JWT |
| Streaming | Server-Sent Events (SSE) — real-time token streaming |
| File Processing | PDF (pdfplumber + PaddleOCR), Excel, Word, Audio |

---

## 4. API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/chat/completions` | POST | OpenAI-compatible chat |
| `/v1/chat` | POST | Native chat (stream/non-stream) |
| `/v1/files/ask` | POST | Upload file + ask question |
| `/v1/files/store` | POST | Store doc in RAG database |
| `/v1/files/query` | POST | Search stored documents |
| `/v1/ocr/upload` | POST | OCR image/PDF → text |
| `/v1/ocr` | POST | OCR from base64 image |
| `/v1/projects` | POST/GET | Create/list AI projects |
| `/v1/projects/{id}` | GET/PUT/DELETE | Manage project |
| `/v1/models` | GET | List available models |
| `/auth/signup` | POST | Create user account |
| `/auth/login` | POST | Login → get JWT token |
| `/v1/api-keys/create` | POST | Create API key |
| `/health` | GET | System health check |

---

## 5. Business Model Options

### Option A — SaaS API (Pay per request)
Charge clients per 1,000 API calls or per token used.

| Plan | Requests/month | Price |
|------|---------------|-------|
| Starter | 10,000 | ₹999/month |
| Business | 100,000 | ₹4,999/month |
| Enterprise | Unlimited | Custom |

### Option B — Single Use Case Product
Build a focused product on top of the platform.

| Product | Use Case | Target Market |
|---------|----------|---------------|
| InvoiceAI | Invoice → JSON extraction | CA firms, accounting |
| DocChat | Document Q&A | Legal, HR, compliance |
| SupportBot | Customer support chat | E-commerce, SaaS |
| CodeReview | Code generation/review | Dev teams |
| KYC Verify | ID card extraction | Banks, fintech |

### Option C — White-label for Enterprise
Give a company the full platform under their brand. One-time setup fee + monthly hosting.

---

## 6. Deployment Status

| Component | Status | Notes |
|-----------|--------|-------|
| AI Model (vLLM) | ✅ Running | Port 1111 — Qwen3.6-35B |
| Production Gateway | ✅ Running | Port 2222 — FastAPI |
| MySQL Database | ✅ Running | All tables created |
| API Key Auth | ✅ Working | sk-ava- prefix |
| Chat / Streaming | ✅ Working | SSE streaming |
| File Upload + Q&A | ✅ Working | PDF, Excel, CSV, images |
| Invoice → JSON | ✅ Working | Any invoice format |
| OCR | ✅ Working | PaddleOCR |
| Map-Reduce Pipeline | ✅ Working | Large doc handling |
| RAG (ChromaDB) | ✅ Built | Needs testing |
| Projects Feature | ✅ Built | Multi-tenant ready |
| Dev Tester UI | ✅ Running | Port 8888 |
| Public Platform (IIS) | ⚠️ Pending | Needs VPS deployment |
| SDK (pip install) | ⚠️ Pending | Needs PyPI publish |

---

## 7. Single Use Case vs Full Platform

**Can you deploy this for just invoice extraction?**  
**Yes.** Create one Project with the invoice system prompt. Share only that API key. The client can only do invoice extraction. They never see the other capabilities.

**Can you deploy this for just customer support chat?**  
**Yes.** Same approach — one project, one system prompt, one API key.

**Can you offer the full platform to enterprise clients?**  
**Yes.** They get all use cases with usage tracking, multiple keys, project management, and dashboard.

---

## 8. Security

- All data processed on **private GPU** — nothing sent to OpenAI/Google
- API key authentication on every request
- JWT token auth for dashboard
- Daily rate limits per API key
- Full audit log of every request
- CORS configured
- Input validation on all endpoints

---

## 9. Scalability

| Scale Level | Approach |
|-------------|----------|
| Current | Single RunPod pod, 1 GPU |
| 10x load | Increase vLLM `max-num-seqs` + workers |
| 100x load | Multiple RunPod pods behind load balancer |
| Enterprise | Multi-GPU tensor parallel, dedicated hardware |

---

## 10. Summary

| Question | Answer |
|----------|--------|
| Can it do general chat? | ✅ Yes |
| Can it do invoice to JSON only? | ✅ Yes |
| Can it do document Q&A? | ✅ Yes |
| Can it handle large PDFs? | ✅ Yes (map-reduce pipeline) |
| Can it be white-labeled? | ✅ Yes |
| Can one platform serve multiple products? | ✅ Yes (Projects feature) |
| Is data private? | ✅ Yes — fully self-hosted |
| Is it OpenAI compatible? | ✅ Yes — drop-in replacement |
| What is the cost per API call? | Infrastructure cost only (no per-token fee to 3rd party) |

---

*Avaniko AI Platform — Built on RunPod | Powered by Qwen3.6-35B | June 2026*
