"""
Isolated OCR microservice for the Avaniko gateway.
Runs on 127.0.0.1:7780. PaddleOCR is unstable (occasional C++ segfaults);
keeping it in its OWN process means a crash restarts only this service —
the main gateway never goes down. Started under an auto-restart loop.
"""
import io
import logging
import os
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from PIL import Image
import numpy as np

os.environ.setdefault("OMP_NUM_THREADS", "1")  # >1 segfaults Paddle on this build
logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
log = logging.getLogger("ocr")

app = FastAPI(title="Avaniko OCR")
_fast = None
_full = None


def _patch_paddle():
    try:
        import paddlex.inference as _px
        if getattr(_px.PaddlePredictorOption, "_patched", False):
            return
        _orig = _px.PaddlePredictorOption.__init__
        def _init(self, *a, **k):
            _orig(self, **{kk: vv for kk, vv in k.items()})
            if a:
                self.setdefault_by_model_name(a[0])
        _px.PaddlePredictorOption.__init__ = _init
        _px.PaddlePredictorOption._patched = True
    except Exception:
        pass


def _engine(full: bool):
    global _fast, _full
    from paddleocr import PaddleOCR
    _patch_paddle()
    if full:
        if _full is None:
            _full = PaddleOCR(lang="en", device="cpu",
                              use_doc_orientation_classify=True,
                              use_doc_unwarping=True,
                              use_textline_orientation=True)
        return _full
    if _fast is None:
        # orientation classify + textline orientation are cheap classifier
        # passes (fix 90/180/270 rotation) — worth always running. Unwarping
        # (curved/warped scans) is the heavy model, kept for the full-engine
        # fallback only. Without this, a rotated page OCRs into readable-length
        # gibberish that passes the char-count fallback check below, so the
        # rotation was never actually getting corrected.
        _fast = PaddleOCR(lang="en", device="cpu",
                          use_doc_orientation_classify=True,
                          use_doc_unwarping=False,
                          use_textline_orientation=True)
    return _fast


def _parse(result) -> str:
    lines = []
    for page in result:
        texts = page.get("rec_texts", []) if hasattr(page, "get") else []
        lines.extend(texts)
    return "\n".join(lines)


def _ocr(arr, full: bool) -> str:
    return _parse(_engine(full).ocr(arr))


@app.post("/ocr")
async def ocr(request: Request):
    body = await request.body()
    try:
        img = Image.open(io.BytesIO(body)).convert("RGB")
        w, h = img.size
        if max(w, h) > 2400:
            s = 2400 / max(w, h); img = img.resize((int(w*s), int(h*s)), Image.LANCZOS)
        elif max(w, h) < 1200:
            s = 1600 / max(w, h); img = img.resize((int(w*s), int(h*s)), Image.LANCZOS)
        arr = np.array(img)
    except Exception as e:
        return JSONResponse(status_code=400, content={"text": "", "error": f"bad image: {e}"})

    text = _ocr(arr, full=False)
    if len(text.strip()) < 30:                 # blank → rotated/warped, try full engine
        full = _ocr(arr, full=True)
        if len(full.strip()) > len(text.strip()):
            text = full
    return {"text": text, "chars": len(text)}


@app.get("/health")
def health():
    return {"ok": True}


@app.on_event("startup")
def warm():
    try:
        _engine(False); _engine(True)
        log.info("OCR engines ready")
    except Exception as e:
        log.warning(f"warmup failed: {e}")
