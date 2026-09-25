#!/bin/bash
# Keeps vLLM (port 7777) self-healing.
#
# vLLM's own EngineCore can die outright from a CUDA "illegal memory access"
# inside its fused kernels (hit 2026-09-21 09:02:29 in the MoE shared-experts
# stream, and again 2026-09-22 06:16:45 in the GDN attention kernel — two
# different code paths, same symptom, not something one env var fixes for
# good). When that happens the APIServer process stays alive, keeps port
# 7777 open, and correctly answers /health with 503 (vllm's own health.py
# catches EngineDeadError and returns 503) — but nothing was ever polling
# that endpoint, so the 2026-09-22 outage sat undetected for ~21 minutes
# until a human noticed and restarted it by hand. This loop closes that gap
# the same way gateway_watchdog.sh already does for the gateway: poll
# /health, two consecutive failures (~30s) -> kill and restart.
#
# On first start, if a healthy vLLM is already running (tracked in
# vllm.pid), this ADOPTS it instead of restarting it — so installing this
# watchdog never causes an avoidable production outage of its own.
set -u
LOGS=/workspace/logs

while true; do
  if curl -sf -m 5 http://localhost:7777/health >/dev/null 2>&1 \
     && [ -f "$LOGS/vllm.pid" ] \
     && kill -0 "$(cat "$LOGS/vllm.pid" 2>/dev/null)" 2>/dev/null; then
    VLLM_PID="$(cat "$LOGS/vllm.pid")"
    echo "$(date '+%F %T') adopting already-running vLLM, PID $VLLM_PID"
    READY=1
  else
    bash /workspace/vllm_start.sh >> "$LOGS/vllm.log" 2>&1 &
    VLLM_PID=$!
    echo "$VLLM_PID" > "$LOGS/vllm.pid"
    echo "$(date '+%F %T') vLLM started, PID $VLLM_PID"

    # Grace period: cold-start model load + torch.compile warmup takes
    # 1-5 min. Don't count health-check failures against it until it has
    # answered at least once, or this window (10 min) elapses.
    READY=0
    for i in $(seq 1 60); do
      if ! kill -0 "$VLLM_PID" 2>/dev/null; then break; fi
      if curl -sf -m 8 http://localhost:7777/health >/dev/null 2>&1; then
        READY=1
        break
      fi
      sleep 10
    done
    if [ "$READY" = "1" ]; then
      echo "$(date '+%F %T') vLLM READY"
    else
      echo "$(date '+%F %T') vLLM did not become healthy within 10 min"
    fi
  fi

  FAILS=0
  while kill -0 "$VLLM_PID" 2>/dev/null; do
    sleep 15
    if curl -sf -m 8 http://localhost:7777/health >/dev/null 2>&1; then
      FAILS=0
    else
      FAILS=$((FAILS + 1))
      echo "$(date '+%F %T') health check failed ($FAILS/2)"
      if [ "$FAILS" -ge 2 ]; then
        echo "$(date '+%F %T') vLLM unresponsive/dead — killing PID $VLLM_PID"
        kill -9 "$VLLM_PID" 2>/dev/null
        break
      fi
    fi
  done

  # The EngineCore worker runs as a separate multiprocessing child that
  # renames itself "VLLM::EngineCore" — its cmdline does NOT contain
  # "vllm.entrypoints", so it does not match the pattern above and can
  # survive as an orphan holding the full GPU memory reservation if the
  # APIServer parent ever gets killed while the child is still alive
  # (confirmed live on 2026-09-22: an orphaned EngineCore silently blocked
  # every subsequent launch attempt with "Engine core initialization
  # failed" until it was killed by name). Sweep both patterns.
  pkill -9 -f "vllm.entrypoints" 2>/dev/null
  pkill -9 -f "VLLM::" 2>/dev/null

  # Bounded poll instead of `wait`: /workspace is a network-mounted FUSE
  # volume that has put other processes on this box into uninterruptible
  # D-state on a blocked write (see gateway_watchdog.sh) — an unbounded
  # `wait` on that PID could then hang the watchdog itself forever. If it's
  # still lingering after 10s we move on anyway.
  for i in $(seq 1 10); do
    kill -0 "$VLLM_PID" 2>/dev/null || break
    sleep 1
  done

  # Belt-and-suspenders visibility: if the GPU is still not actually free
  # after the sweep above, the next launch will fail with a memory error
  # and this loop will keep retrying every ~15s — harmless but silent
  # otherwise. Log it loudly so it doesn't take a human an hour to notice.
  USED_MB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)"
  if [ -n "${USED_MB:-}" ] && [ "$USED_MB" -gt 2000 ] 2>/dev/null; then
    echo "$(date '+%F %T') WARNING: ${USED_MB}MiB still held on GPU after cleanup — next launch will likely fail and retry"
  fi

  echo "$(date '+%F %T') vLLM process gone — restarting in 5s"
  sleep 5
done
