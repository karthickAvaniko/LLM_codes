# Avaniko AI Platform

Production-grade AI API platform — OpenAI/Gemini compatible.

## Repository Structure

```
├── production/          → RunPod Gateway (private AI backend)
│   ├── main.py          → FastAPI app
│   ├── routers/         → chat, ocr, files, admin, projects
│   ├── services/        → LLM, OCR, embedder, RAG
│   └── start_all.sh     → Start with supervisor (auto-restart)
│
└── avaniko-platform/    → Public API Platform (deploy on IIS/VPS)
    ├── backend/         → FastAPI + PostgreSQL + Redis
    ├── frontend/        → React dashboard
    ├── sdk/             → pip install avaniko-ai
    ├── nginx/           → Reverse proxy + SSL config
    └── docker-compose.yml
```

## Architecture

```
Developer / Client App
        │
        │  https://api.avaniko.com
        ▼
┌─────────────────────────────┐
│   avaniko-platform (IIS)    │  Public-facing API
│   FastAPI + PostgreSQL       │  User management, API keys
│   Redis + pgvector           │  Rate limiting, Vector DB
└────────────┬────────────────┘
             │ Private (RunPod URL hidden)
             ▼
┌─────────────────────────────┐
│   production (RunPod)        │  Private AI backend
│   Qwen3.6 MoE + vLLM        │  Chat, OCR, RAG, Files
│   MySQL + ChromaDB           │
└─────────────────────────────┘
```

## Quick Start

### 1. RunPod Server (production/)
```bash
# Already running on RunPod
bash start_all.sh
```

### 2. IIS Server (avaniko-platform/)
```bash
cd avaniko-platform
cp .env.example .env
# Fill RUNPOD_GATEWAY_URL and secrets in .env

# Deploy with Docker
docker compose up -d --build

# OR deploy on IIS (see DEPLOY.md)
```

### 3. SDK Usage
```python
pip install avaniko-ai

from avaniko_ai import Avaniko
client = Avaniko(api_key="ava-sk-xxxx")
print(client.chat("Hello!"))
```

## API Endpoints

| Endpoint | Description |
|---|---|
| `POST /v1/chat/completions` | Chat (OpenAI compatible) |
| `GET  /v1/models` | List available models |
| `POST /v1/embeddings` | Text embeddings |
| `POST /v1/rag/store` | Store document for RAG |
| `POST /v1/rag/query` | Query stored documents |
| `POST /v1/projects` | Create AI project config |
| `GET  /v1/usage` | Usage statistics |
| `POST /v1/api-keys/create` | Create API key |

## Tech Stack

**RunPod Gateway:** Python, FastAPI, vLLM, MySQL, ChromaDB, PaddleOCR

**IIS Platform:** Python, FastAPI, PostgreSQL, pgvector, Redis, React, Nginx
