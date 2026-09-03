
#!/bin/bash
# Avaniko AI Platform — start everything with persistent logs
# Run this after a pod restart:  bash /workspace/start_all.sh
set -u
LOGS=/workspace/logs
mkdir -p "$LOGS"

echo "── Avaniko AI Platform startup ──"

# ── vLLM (port 7777) ─────────────────────────────────────
if curl -sf http://localhost:7777/health >/dev/null 2>&1; then
  echo "vLLM already running on 7777"
else
  pkill -f "vllm.entrypoints" 2>/dev/null; sleep 3
  nohup /workspace/venv/bin/python -m vllm.entrypoints.openai.api_server \
    --model /workspace/models/Qwen3.6-35B-A3B-GPTQ-Int4 \
    --served-model-name qwen3.6-35b \
    --host 127.0.0.1 --port 7777 \
    --dtype float16 \
    --max-model-len 32768 \
    --gpu-memory-utilization 0.85 \
    --max-num-seqs 8 \
    --max-num-batched-tokens 4096 \
    --trust-remote-code \
    --enable-prefix-caching \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3 \
    --kv-cache-dtype fp8_e4m3 \
    --calculate-kv-scales \
    >> "$LOGS/vllm.log" 2>&1 &
  echo $! > "$LOGS/vllm.pid"
  echo "vLLM starting (PID $(cat $LOGS/vllm.pid)) — model load takes ~5 min"
fi

# ── MySQL (MariaDB, datadir on persistent /workspace, AUTO-RESTART) ────
# The /workspace volume is network-mounted (RunPod MooseFS) and has crashed
# mariadbd multiple times under write load. The loop respawns it immediately
# instead of leaving the DB (and the gateway, which blocks on it) down for
# hours until someone notices.
if mysql -e "SELECT 1" >/dev/null 2>&1; then
  echo "MySQL already running"
elif [ -f "$LOGS/mysql.pid" ] && kill -0 "$(cat "$LOGS/mysql.pid" 2>/dev/null)" 2>/dev/null; then
  echo "MySQL watchdog already running"
else
  command -v mariadbd >/dev/null 2>&1 || {
    echo "Installing MariaDB (container was reset)..."
    apt-get install -y -qq mariadb-server >/dev/null 2>&1 || \
      { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq mariadb-server >/dev/null 2>&1; }
  }
  mkdir -p /run/mysqld
  pkill -f "mariadbd --user=root" 2>/dev/null; sleep 2
  nohup bash -c '
    while true; do
      mariadbd --user=root --datadir=/workspace/mysql --bind-address=127.0.0.1 \
        --socket=/run/mysqld/mysqld.sock \
        --wait-timeout=180 --connect-timeout=20 --innodb-lock-wait-timeout=30
      echo "$(date -u "+%F %T") mariadbd exited — restarting in 3s"
      sleep 3
    done
  ' >> "$LOGS/mysql.log" 2>&1 &
  echo $! > "$LOGS/mysql.pid"
  for i in $(seq 1 30); do mysql -e "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  mysql -e "SELECT 1" >/dev/null 2>&1 && echo "MySQL started (auto-restart loop, PID $(cat $LOGS/mysql.pid))" || echo "MySQL FAILED — check $LOGS/mysql.log"
fi

# ── OCR service (port 7780, localhost, AUTO-RESTART) ────
# PaddleOCR can segfault; the restart loop keeps it self-healing so the
# gateway never goes down with it.
if curl -sf http://127.0.0.1:7780/health >/dev/null 2>&1; then
  echo "OCR service already running on 7780"
else
  pkill -f "ocr_server:app" 2>/dev/null; sleep 1
  nohup bash -c 'while true; do OMP_NUM_THREADS=1 /workspace/gateway/venv/bin/python -m uvicorn ocr_server:app --host 127.0.0.1 --port 7780 --app-dir /workspace; echo "OCR service exited — restarting in 3s"; sleep 3; done' >> "$LOGS/ocr.log" 2>&1 &
  echo $! > "$LOGS/ocr.pid"
  echo "OCR service starting (auto-restart loop, PID $(cat $LOGS/ocr.pid))"
fi

# ── Embedding service (port 7779, localhost only) ───────
if curl -sf http://127.0.0.1:7779/health >/dev/null 2>&1; then
  echo "Embed service already running on 7779"
else
  pkill -f "embed_server:app" 2>/dev/null; sleep 2
  cd /workspace
  nohup /workspace/venv/bin/python -m uvicorn embed_server:app \
    --host 127.0.0.1 --port 7779 >> "$LOGS/embed.log" 2>&1 &
  echo $! > "$LOGS/embed.pid"
  echo "Embed service starting (PID $(cat $LOGS/embed.pid))"
fi

# ── Gateway (port 7778, AUTO-RESTART) ───────────────────
# Can freeze in kernel D-state on a blocked /workspace write without ever
# exiting on its own (observed repeatedly) — gateway_watchdog.sh actively
# health-checks and force-kills/restarts it, rather than just relying on
# the process exiting.
if curl -sf http://localhost:7778/health >/dev/null 2>&1; then
  echo "Gateway already running on 7778"
elif [ -f "$LOGS/gateway_watchdog.pid" ] && kill -0 "$(cat "$LOGS/gateway_watchdog.pid" 2>/dev/null)" 2>/dev/null; then
  echo "Gateway watchdog already running"
else
  pkill -f "uvicorn main:app" 2>/dev/null; sleep 2
  # Watchdog's own status log goes to local disk too — see comment in
  # gateway_watchdog.sh: a blocked write to /workspace here would freeze the
  # watchdog itself, silently disabling the auto-restart it exists to provide.
  nohup bash /workspace/gateway_watchdog.sh >> /tmp/gateway_watchdog.log 2>&1 &
  echo $! > "$LOGS/gateway_watchdog.pid"
  echo "Gateway starting (auto-restart loop, watchdog PID $(cat $LOGS/gateway_watchdog.pid))"
fi

# ── Daily backup loop ────────────────────────────────────
if [ -f "$LOGS/backup.pid" ] && kill -0 "$(cat "$LOGS/backup.pid")" 2>/dev/null; then
  echo "Backup loop already running"
else
  nohup bash -c 'while true; do bash /workspace/backup.sh >> /workspace/logs/backup.log 2>&1; sleep 86400; done' \
    >/dev/null 2>&1 &
  echo $! > "$LOGS/backup.pid"
  echo "Backup loop started (daily, keeps 14 days)"
fi

# ── Wait for vLLM ────────────────────────────────────────
echo "Waiting for vLLM..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:7777/health >/dev/null 2>&1; then
    echo "vLLM READY"
    break
  fi
  sleep 10
done

echo ""
echo "── Status ──"
curl -s http://localhost:7778/health && echo ""
echo "API key : $(cat /workspace/gateway/.api_key 2>/dev/null || echo 'not generated yet')"
echo "Logs    : $LOGS/ (vllm.log, gateway.log, access.jsonl, requests.jsonl)"
echo "App log : /tmp/avaniko_gateway_logs/gateway_app.log (moved off the network volume)"
