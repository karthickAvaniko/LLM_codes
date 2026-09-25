
#!/bin/bash
# Avaniko AI Platform — start everything with persistent logs
# Run this after a pod restart:  bash /workspace/start_all.sh
set -u
export TZ='Asia/Kolkata'   # all log timestamps in this file and its child processes are IST, not UTC
LOGS=/workspace/logs
mkdir -p "$LOGS"

echo "── Avaniko AI Platform startup ──"

# ── vLLM (port 7777, AUTO-RESTART) ───────────────────────
# EngineCore can die outright from a CUDA "illegal memory access" inside its
# fused kernels (hit 2026-09-21 and again 2026-09-22, two different kernels,
# same symptom — see vllm_start.sh) while the APIServer process stays alive,
# keeps the port open, and correctly reports 503 on /health — but nothing
# was polling that endpoint, so the 2026-09-22 crash sat undetected for ~21
# minutes until a human noticed. vllm_watchdog.sh actively health-checks and
# kills/restarts on 2 consecutive failures, same pattern as
# gateway_watchdog.sh below. The actual launch command lives in
# vllm_start.sh so start_all.sh and the watchdog never drift apart.
if curl -sf http://localhost:7777/health >/dev/null 2>&1; then
  echo "vLLM already running on 7777"
elif [ -f "$LOGS/vllm_watchdog.pid" ] && kill -0 "$(cat "$LOGS/vllm_watchdog.pid" 2>/dev/null)" 2>/dev/null; then
  echo "vLLM watchdog already running"
else
  pkill -f "vllm.entrypoints" 2>/dev/null; sleep 3
  nohup bash /workspace/vllm_watchdog.sh >> /tmp/vllm_watchdog.log 2>&1 &
  echo $! > "$LOGS/vllm_watchdog.pid"
  echo "vLLM starting (auto-restart loop, watchdog PID $(cat $LOGS/vllm_watchdog.pid)) — model load takes ~5 min"
fi

# ── MySQL (MariaDB, datadir on persistent /workspace, AUTO-RESTART) ────
# The /workspace volume is network-mounted (RunPod MooseFS) and has crashed
# mariadbd multiple times under write load. The loop respawns it immediately
# instead of leaving the DB (and the gateway, which blocks on it) down for
# hours until someone notices.
if mysql -e "SELECT 1" >/dev/null 2>&1; then
  echo "MySQL already running"
elif ss -ltn 2>/dev/null | grep -qE '[:.]3306[[:space:]]'; then
  # Port 3306 is held by a server we cannot log into. This is the distro's
  # mariadb.service on datadir /var/lib/mysql, which systemd auto-enables when
  # the apt-get install below ever runs, and which then wins the race against
  # this script on every reboot. It has none of the platform's users and no
  # avaniko database, so the gateway dies at import with
  #   pymysql.err.OperationalError: (1045, "Access denied for user 'avaniko'")
  # while the watchdog loop below would respawn the real server every 3s
  # against "Can't start server: Bind on TCP/IP port ... Address already in
  # use" forever. Two crashloops, no recovery. Fail loudly instead.
  echo "MySQL ERROR: port 3306 is held by a foreign server, not /workspace/mysql."
  echo "  Cause: distro mariadb.service (datadir /var/lib/mysql) started at boot."
  echo "  Fix  : sudo systemctl disable --now mariadb   then re-run this script."
elif [ -f "$LOGS/mysql.pid" ] && kill -0 "$(cat "$LOGS/mysql.pid" 2>/dev/null)" 2>/dev/null; then
  echo "MySQL watchdog already running"
else
  command -v mariadbd >/dev/null 2>&1 || {
    echo "Installing MariaDB (container was reset)..."
    apt-get install -y -qq mariadb-server >/dev/null 2>&1 || \
      { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq mariadb-server >/dev/null 2>&1; }
  }
  # /run is a root-owned tmpfs, wiped on every boot, and the ubuntu user this
  # loop runs as cannot mkdir inside it. The socket dir used to appear only as a
  # side effect of the distro mariadb.service starting — which is precisely the
  # service that must stay disabled, because it squats on 3306 with the wrong
  # datadir (/var/lib/mysql) and took the whole platform down on 2026-09-21.
  # Without this, mariadbd aborts with "Bind on unix socket: Permission denied".
  if [ ! -d /run/mysqld ] || [ ! -w /run/mysqld ]; then
    sudo mkdir -p /run/mysqld && sudo chown "$(id -un):$(id -gn)" /run/mysqld
  fi
  pkill -f "mariadbd --user=root" 2>/dev/null; sleep 2
  nohup bash -c '
    while true; do
      mariadbd --user=root --datadir=/workspace/mysql --bind-address=127.0.0.1 \
        --socket=/run/mysqld/mysqld.sock \
        --wait-timeout=180 --connect-timeout=20 --innodb-lock-wait-timeout=30
      echo "$(date "+%F %T") mariadbd exited — restarting in 3s"
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

# ── Public port forward 20007 → gateway 7778 (AUTO-RESTART) ──
# This pod has no public IP of its own: eth0 is a private /32 (192.168.100.139)
# and the host NATs public <pod-ip>:20007 through to this container's 20007, so
# something inside must listen there or the public endpoint simply refuses.
# socat did that job, started by hand on 2026-09-17 06:51 — and died unnoticed,
# exactly like cloudflared did, because nothing supervised it. Hence the loop.
#
# This is a plain TCP relay onto a plain-HTTP origin, so the public endpoint is
# http://<ip>:20007, NOT https:// — there is no TLS anywhere in this path.
# Auth is only the gateway's bearer token (/workspace/gateway/.api_key), sent
# in clear over the public internet on this route. Prefer the Cloudflare tunnel
# (real TLS) for anything beyond testing.
if ss -ltn 2>/dev/null | grep -qE '[:.]20007[[:space:]]'; then
  echo "Port forward 20007 already running"
else
  nohup bash -c '
    while true; do
      socat TCP-LISTEN:20007,fork,reuseaddr TCP:127.0.0.1:7778
      echo "$(date "+%F %T") socat 20007 exited — restarting in 3s"
      sleep 3
    done
  ' >> "$LOGS/socat_20007.log" 2>&1 &
  echo $! > "$LOGS/socat_20007.pid"
  echo "Port forward 20007 → 7778 started (auto-restart, PID $(cat $LOGS/socat_20007.pid))"
fi

# ── Public port forward 20006 → gateway 7778 (AUTO-RESTART) ──
# Second public endpoint onto the same gateway, added 2026-09-22 because the
# host also NATs <pod-ip>:20006 through to this container. Same caveats as
# 20007 above: plain TCP relay onto a plain-HTTP origin, so the public URL is
# http://<ip>:20006 — https:// will NOT connect, there is no TLS on this path.
if ss -ltn 2>/dev/null | grep -qE '[:.]20006[[:space:]]'; then
  echo "Port forward 20006 already running"
else
  nohup bash -c '
    while true; do
      socat TCP-LISTEN:20006,fork,reuseaddr TCP:127.0.0.1:7778
      echo "$(date "+%F %T") socat 20006 exited — restarting in 3s"
      sleep 3
    done
  ' >> "$LOGS/socat_20006.log" 2>&1 &
  echo $! > "$LOGS/socat_20006.pid"
  echo "Port forward 20006 → 7778 started (auto-restart, PID $(cat $LOGS/socat_20006.pid))"
fi

# ── Public port forward 20004 → gateway 7778 (AUTO-RESTART) ──
# Added 2026-09-22: 20004 is the port the host actually NATs through to this
# container (20006 was tried first and is NOT mapped — it refuses publicly).
# Plain TCP relay onto a plain-HTTP origin, same as 20007: the public URL is
# http://<ip>:20004 — https:// will NOT connect, there is no TLS on this path.
if ss -ltn 2>/dev/null | grep -qE '[:.]20004[[:space:]]'; then
  echo "Port forward 20004 already running"
else
  nohup bash -c '
    while true; do
      socat TCP-LISTEN:20004,fork,reuseaddr TCP:127.0.0.1:7778
      echo "$(date "+%F %T") socat 20004 exited — restarting in 3s"
      sleep 3
    done
  ' >> "$LOGS/socat_20004.log" 2>&1 &
  echo $! > "$LOGS/socat_20004.pid"
  echo "Port forward 20004 → 7778 started (auto-restart, PID $(cat $LOGS/socat_20004.pid))"
fi

# ── Internal 9999 → gateway 7778 (AUTO-RESTART) — THE LIVE PUBLIC PATH ──
# The provider dashboard ("Exposed Services") maps internal 9999 → public
# 50.35.188.68:20004. The dashboard side only NATs; something must LISTEN on
# 9999 inside the pod or the public address refuses. Two outages were caused by
# exactly this: "1111 → 20007" and "9999 → 20004" both pointed at dead internal
# ports while the gateway was healthy on 7778 the whole time.
#
# Public URL is http://50.35.188.68:20004 — plain HTTP, NO TLS on this path.
# NOTE: the provider reassigns the PUBLIC port on every pod reset, so re-check
# the dashboard row after a restart; the internal port (9999) stays ours.
if ss -ltn 2>/dev/null | grep -qE '[:.]9999[[:space:]]'; then
  echo "Internal 9999 forward already running"
else
  nohup bash -c '
    while true; do
      socat TCP-LISTEN:9999,fork,reuseaddr TCP:127.0.0.1:7778
      echo "$(date "+%F %T") socat 9999 exited — restarting in 3s"
      sleep 3
    done
  ' >> "$LOGS/socat_9999.log" 2>&1 &
  echo $! > "$LOGS/socat_9999.pid"
  echo "Internal 9999 → 7778 started (public 20004, auto-restart, PID $(cat $LOGS/socat_9999.pid))"
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
