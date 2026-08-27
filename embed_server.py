"""
Local embedding service for the Avaniko gateway RAG pipeline.
Runs on 127.0.0.1:7779 only — never exposed publicly.
Model: all-MiniLM-L6-v2 (384-dim, CPU — a few ms per batch).
"""
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer

app = FastAPI(title="Avaniko Embeddings")
model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2", device="cpu")


class EmbedRequest(BaseModel):
    texts: list[str]


@app.post("/embed")
def embed(req: EmbedRequest):
    vecs = model.encode(req.texts, normalize_embeddings=True, batch_size=64,
                        show_progress_bar=False)
    return {"vectors": vecs.tolist()}


@app.get("/health")
def health():
    return {"ok": True, "model": "all-MiniLM-L6-v2", "dim": 384}
