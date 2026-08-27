# Avaniko AI — RunPod Deployment Guide (A to Z)

How to deploy the entire Avaniko AI platform on a fresh RunPod pod, from zero to a
working public API. Written for the current setup (RTX A6000 48GB, Qwen3.6-35B).

---

## 0. Architecture recap

Five services run inside one pod. Only the gateway (7778) is public.

```
Internet → RunPod Proxy (https://<POD_ID>-7778.proxy.runpod.net)
   → Gateway        :7778  (public)  — API keys, routing, UI, docs pipeline
       → vLLM       :7777  (localhost) — Qwen3.6-35B on GPU
       → Embeddings :7779  (localhost) — RAG vectors (MiniLM, CPU)
       → OCR        :7780  (localhost) — PaddleOCR, isolated + auto-restart
       → MySQL      :3306  (localhost) — api_keys, users, sessions
   + daily backup loop → /workspace/backups
```

Everything lives under `/workspace` (RunPod's persistent volume) so it survives
pod stop/start. Only a pod **terminate** (volume delete) loses data.

---

## 1. Create the pod

1. RunPod → Deploy → GPU: **RTX A6000 (48 GB)** (or any ≥40 GB GPU).
2. Template: a PyTorch/CUDA image (CUDA 12.x).
3. **Volume:** attach a persistent volume mounted at `/workspace` (≥120 GB).
4. **Expose HTTP port: `7778` only.** Do NOT expose 7777/7779/7780 — they must stay private.
5. Expose TCP `22` if you want SSH.
6. Deploy and open a terminal (web terminal or SSH).

Find your pod id:
```bash
echo $RUNPOD_POD_ID    # e.g. s2f1q59mb9tg9r
```
Your public URL is `https://<POD_ID>-7778.proxy.runpod.net`.

---

## 2. One-time setup (first deploy only)

### 2.1 System packages
```bash
apt-get update && apt-get install -y mariadb-server curl git
```

### 2.2 Python environments
Two venvs are used:
- `/workspace/venv` — vLLM + embeddings (sentence-transformers, torch, numpy 2.x)
- `/workspace/gateway/venv` — gateway + PaddleOCR (**numpy 1.26.4**, paddleocr 3.1.1)

```bash
# main venv (vLLM, embeddings)
python3 -m venv /workspace/venv
/workspace/venv/bin/pip install vllm sentence-transformers fastapi uvicorn

# gateway venv (gateway + OCR)  — keep numpy 1.26 here
python3 -m venv /workspace/gateway/venv
/workspace/gateway/venv/bin/pip install fastapi uvicorn httpx pymupdf pillow \
    paddleocr==3.1.1 "numpy==1.26.4" pymysql python-docx pandas openpyxl ddgs numpy
```
> CRITICAL: the gateway venv must have **numpy 1.26.4**. numpy 2.0 breaks PaddleOCR
> (`np.sctypes` removed) and OCR will crash-loop.

### 2.3 Download the model
```bash
mkdir -p /workspace/models
# place Qwen3.6-35B-A3B-GPTQ-Int4 in /workspace/models/
# (huggingface-cli download ... --local-dir /workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4)
```

### 2.4 Initialise MySQL (data on persistent volume)
```bash
mkdir -p /workspace/mysql /run/mysqld
mariadb-install-db --user=root --datadir=/workspace/mysql
nohup mariadbd --user=root --datadir=/workspace/mysql \
    --bind-address=127.0.0.1 --socket=/run/mysqld/mysqld.sock &
sleep 5
DBPASS=$(openssl rand -hex 16)
mysql <<EOF
CREATE DATABASE IF NOT EXISTS avaniko CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'avaniko'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON avaniko.* TO 'avaniko'@'localhost';
FLUSH PRIVILEGES;
EOF
echo "MYSQL_PASSWORD=$DBPASS" > /workspace/gateway/.mysql_env
chmod 600 /workspace/gateway/.mysql_env
```
Tables (`api_keys`, `users`, `sessions`) are created automatically by the gateway
on first start, or apply `/workspace/gateway/avaniko_db.sql` from a backup.

### 2.5 Code files (already in /workspace if restoring from backup)
- `/workspace/gateway/main.py` — the gateway
- `/workspace/gateway/static/` — chat UI, console, admin pages
- `/workspace/embed_server.py` — embeddings service
- `/workspace/ocr_server.py` — OCR service
- `/workspace/start_all.sh` — boots everything
- `/workspace/backup.sh` — daily backup

---

## 3. Start everything

```bash
bash /workspace/start_all.sh
```

This script (in order):
1. Starts **MySQL** (installs MariaDB if the image was reset).
2. Starts **OCR** service on 7780 under an auto-restart loop (`OMP_NUM_THREADS=1`).
3. Starts **embeddings** on 7779.
4. Starts **vLLM** on 7777 (`127.0.0.1`, model load ~5 min).
5. Starts the **gateway** on 7778.
6. Starts the **daily backup** loop.

Wait ~5 minutes for the model to load, then verify (section 5).

---

## 4. Key config values (in start_all.sh / gateway)

| Setting | Value | Where |
|---|---|---|
| vLLM model | `/workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4` | start_all.sh |
| Served name | `qwen3.6-35b` (public: `avaniko-ai`) | start_all.sh / main.py |
| Context length | 32768 | `--max-model-len` |
| GPU memory | 0.85 | `--gpu-memory-utilization` |
| Concurrent seqs | 8 | `--max-num-seqs` |
| Speed flags | `--enable-prefix-caching` (no `--enforce-eager`) | start_all.sh |
| vLLM host | `127.0.0.1` (private!) | start_all.sh |
| OCR threads | `OMP_NUM_THREADS=1` (must be 1) | start_all.sh |

---

## 5. Verify the deployment

```bash
curl http://localhost:7778/health          # {"gateway":"ok","vllm":"ok",...}
curl http://127.0.0.1:7780/health          # {"ok":true}  (OCR)
curl http://127.0.0.1:7779/health          # {"ok":true}  (embeddings)
mysql avaniko -e "SHOW TABLES;"            # api_keys, sessions, users

# end-to-end: create a key and call it
ADMIN=$(cat /workspace/gateway/.api_key)
KEY=$(curl -s -X POST http://localhost:7778/admin/keys -H "Authorization: Bearer $ADMIN" \
  -H "Content-Type: application/json" -d '{"name":"test"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['api_key'])")
curl -s http://localhost:7778/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say OK"}]}'
```

Also confirm 7777 is NOT public:
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<POD_ID>-7777.proxy.runpod.net/health
# expect 502 (closed). If 200, remove 7777 from exposed ports.
```

---

## 6. After a pod STOP/START (data preserved)

Just re-run:
```bash
bash /workspace/start_all.sh
```
Everything (keys, users, files, model) is on `/workspace` and persists.
If the container image reset removed MariaDB, start_all.sh reinstalls it; the
data directory `/workspace/mysql` is untouched.

---

## 7. Backups & recovery

- Daily auto-backup → `/workspace/backups/avaniko_YYYY-MM-DD.tar.gz` (14-day retention),
  includes MySQL dump (`avaniko_db.sql`), keys, code, UI.
- Manual backup: `bash /workspace/backup.sh`
- Restore MySQL: `mysql avaniko < /workspace/gateway/avaniko_db.sql`
- **Strongly recommended:** copy the daily tarball off-pod (S3 / Google Drive),
  because a pod *terminate* deletes the volume. Without an off-site copy, terminate = total loss.

---

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `health` shows `"vllm":"down"` | Model still loading (~5 min) or crashed — check `/workspace/logs/vllm.log` |
| OCR `/health` down | `bash /workspace/start_all.sh` re-launches it; ensure `OMP_NUM_THREADS=1` and gateway venv (numpy 1.26) |
| OCR crash-loop with `np.sctypes` | Wrong venv — must use `/workspace/gateway/venv` (numpy 1.26.4) |
| 401 on every call | Wrong/expired key; check `/workspace/gateway/.api_key` for admin |
| 524 timeout on big PDFs | Use `/v1/files` (upload + poll) instead of synchronous calls |
| Gateway won't start | `python -c "import ast; ast.parse(open('/workspace/gateway/main.py').read())"` to check syntax; see `/workspace/logs/gateway.log` |

Logs live in `/workspace/logs/`:
`vllm.log`, `gateway.log`, `gateway_app.log`, `ocr_v2.log`, `embed.log`,
`mysql.log`, `backup.log`, `access.jsonl`, `requests.jsonl`.

---

## 9. Scaling (when needed)

- More concurrent users: raise `--max-num-seqs` (8 → 16); watch VRAM.
- Faster scanned-document OCR: move PaddleOCR to GPU (lower vLLM
  `--gpu-memory-utilization` to ~0.78 first, then load-test for OOM).
- More throughput: add a second GPU pod + a load balancer in front of 7778.
- Custom domain: put Cloudflare in front, point `api.avaniko.com` → the pod URL,
  so integrations never break when the pod id changes.

---

## 10. Security checklist

- [ ] Only port 7778 exposed publicly (7777/7779/7780 private)
- [ ] vLLM bound to 127.0.0.1
- [ ] Public self-signup closed for internal phase (`AVANIKO_SELF_SIGNUP` unset)
- [ ] `.api_key` and `.mysql_env` are chmod 600
- [ ] Daily backups copied off-pod
- [ ] API keys kept server-side in consuming apps
```
