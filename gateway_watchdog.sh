#!/bin/bash
# Keeps the gateway (port 7778) self-healing.
#
# Unlike a plain "restart on exit" loop, this also catches the gateway
# freezing without exiting (observed repeatedly: a blocked write to the
# network-mounted /workspace volume puts it in kernel D-state, unresponsive
# to everything including its own /health, but never exits on its own).
# Two consecutive failed health checks (~30s) triggers a kill + restart.
set -u
LOGS=/workspace/logs
# App + watchdog logs go to LOCAL disk (/tmp), not /workspace — /workspace is
# a network-mounted FUSE volume that intermittently stalls on writes, and a
# blocked log write there freezes the whole single-worker event loop (or,
# for the watchdog's own status line, freezes the watchdog itself, silently
# disabling the auto-restart it exists to provide). /tmp survives only for
# the container's lifetime, which is an acceptable tradeoff for staying up.
LOCAL_LOGS=/tmp

while true; do
  bash /workspace/gateway/start.sh >> "$LOCAL_LOGS/gateway.log" 2>&1 &
  GW_PID=$!
  echo "$GW_PID" > "$LOGS/gateway.pid"
  echo "$(date -u '+%F %T') gateway started, PID $GW_PID"

  FAILS=0
  while kill -0 "$GW_PID" 2>/dev/null; do
    sleep 15
    if curl -sf -m 8 http://localhost:7778/health >/dev/null 2>&1; then
      FAILS=0
    else
      FAILS=$((FAILS + 1))
      echo "$(date -u '+%F %T') health check failed ($FAILS/2)"
      if [ "$FAILS" -ge 2 ]; then
        echo "$(date -u '+%F %T') gateway unresponsive — killing PID $GW_PID"
        kill -9 "$GW_PID" 2>/dev/null
        break
      fi
    fi
  done

  wait "$GW_PID" 2>/dev/null
  echo "$(date -u '+%F %T') gateway process gone — restarting in 3s"
  sleep 3
done
