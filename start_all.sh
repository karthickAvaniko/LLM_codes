
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
  export FLASHINFER_CUDA_ARCH_LIST="12.0f"
  export VLLM_USE_DEEP_GEMM=0
  nohup /workspace/venv/bin/python -m vllm.entrypoints.openai.api_server \
    --model /workspace/models/Qwen3.6-35B-A3B-FP8 \
    --served-model-name qwen3.6-35b \
    --host 127.0.0.1 --port 7777 \
    --dtype auto \
    --max-model-len 65536 \
    --gpu-memory-utilization 0.85 \
    --max-num-seqs 8 \
    --max-num-batched-tokens 4096 \
    --trust-remote-code \
    --enable-prefix-caching \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3 \
    --kv-cache-dtype fp8_e4m3 \
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

# ── OCR service pool (ports 7780-7783, localhost, AUTO-RESTART) ─
# PaddleOCR can segfault; each port runs its own restart loop so the
# gateway never goes down with it. 4 isolated processes (not 4 threads
# in one process) because the /ocr handler blocks the event loop during
# inference — one process serialize per request, so throughput comes
# from running several processes, each pinned to a single CPU thread
# (OMP/OPENBLAS/MKL=1 — >1 OMP thread segfaults Paddle on this build,
# and the container's real cgroup CPU quota is only ~6 cores regardless
# of what `nproc` reports, so keeping each worker single-threaded avoids
# oversubscribing it).
#
# Each loop tracks its OWN uvicorn worker PID in ocr_<port>_worker.pid,
# separate from the wrapper's PID. Restarting a worker must kill only
# that tracked PID — never `pkill -f ocr_server:app`, since that string
# also appears inside this wrapper's own command line and would kill the
# restart loop itself, permanently disabling auto-restart.
#
# Thread count of 2 (not 1) per instance was chosen by benchmarking, not
# assumption: even though 4 instances x 2 threads = 8 requested threads
# against a real ~6-core cgroup quota (oversubscribed), 2 threads beat 1
# thread across every concurrency level tested (single request: 5.9s vs
# 10.5s; 4 concurrent: 8.4s vs 10.8s; 8 concurrent: 15.9s vs 20.9s wall
# time). Re-benchmark with /tmp/ocr_bench/bench.py if the CPU quota or
# instance count changes.
#
# Requires paddlepaddle==3.0.0 specifically (matches PaddleOCR 3.1.1's
# documented compatible version) — paddlepaddle 3.3.1 (latest at time of
# writing) has a PIR/oneDNN executor bug that crashes every real OCR
# request with "ConvertPirAttribute2RuntimeAttribute not support".
OCR_PORTS=(7780 7781 7782 7783)
for OCR_PORT in "${OCR_PORTS[@]}"; do
  if curl -sf http://127.0.0.1:$OCR_PORT/health >/dev/null 2>&1; then
    echo "OCR service already running on $OCR_PORT"
    continue
  fi
  WPID_FILE="$LOGS/ocr_${OCR_PORT}_worker.pid"
  if [ -f "$WPID_FILE" ] && kill -0 "$(cat "$WPID_FILE" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$WPID_FILE")" 2>/dev/null
  fi
  nohup bash -c "
    while true; do
      OMP_NUM_THREADS=2 OPENBLAS_NUM_THREADS=2 MKL_NUM_THREADS=2 PADDLE_PDX_CPU_NUM_THREADS=2 \\
        /workspace/gateway/venv/bin/python -m uvicorn ocr_server:app --host 127.0.0.1 --port $OCR_PORT --app-dir /workspace &
      echo \$! > '$WPID_FILE'
      wait \$!
      echo \"OCR $OCR_PORT worker exited — restarting in 3s\"
      sleep 3
    done
  " >> "$LOGS/ocr_${OCR_PORT}.log" 2>&1 &
  echo $! > "$LOGS/ocr_${OCR_PORT}_wrapper.pid"
  echo "OCR service starting on $OCR_PORT (wrapper PID $(cat "$LOGS/ocr_${OCR_PORT}_wrapper.pid"))"
done

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
