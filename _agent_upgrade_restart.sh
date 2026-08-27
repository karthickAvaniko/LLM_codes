#!/bin/bash
# Idle-gated restart to activate tool-calling (vLLM flags + gateway passthrough).
# Waits for 5 continuous minutes of NO API traffic before taking the ~5-min
# vLLM reload outage, so a live office OCR request never gets cut off.
IDLE=300            # require 5 min with no requests
MAXWAIT=43200       # stop watching after 12h if never idle
ACCESS=/workspace/logs/access.jsonl
LOG=/workspace/logs/agent_upgrade_restart.log
KEY=$(cat /workspace/gateway/.api_key)
start=$(date +%s)

echo "[$(date -u +%FT%TZ)] watcher started — waiting for ${IDLE}s idle gap" >> "$LOG"
while true; do
  now=$(date +%s)
  last=$(stat -c %Y "$ACCESS" 2>/dev/null || echo 0)
  if [ $(( now - last )) -ge "$IDLE" ]; then
    echo "[$(date -u +%FT%TZ)] idle $((now-last))s — applying restart NOW" >> "$LOG"
    break
  fi
  if [ $(( now - start )) -ge "$MAXWAIT" ]; then
    echo "[$(date -u +%FT%TZ)] 12h elapsed, never idle — ABORTED, no restart" >> "$LOG"
    exit 0
  fi
  sleep 30
done

{
  echo "[$(date -u +%FT%TZ)] stopping vLLM + gateway…"
  pkill -f vllm.entrypoints 2>/dev/null
  pkill -f "uvicorn main:app" 2>/dev/null
  sleep 3
  echo "[$(date -u +%FT%TZ)] running start_all.sh (restarts only the down services)…"
  bash /workspace/start_all.sh
  echo "waiting for vLLM model load (~5 min)…"
  for i in $(seq 1 120); do curl -sf http://127.0.0.1:7777/health >/dev/null 2>&1 && break; sleep 5; done
  curl -sf http://127.0.0.1:7777/health >/dev/null 2>&1 && echo "vLLM UP" || echo "vLLM STILL DOWN — check logs/vllm.log"
  for i in $(seq 1 24); do curl -sf http://localhost:7778/health >/dev/null 2>&1 && break; sleep 5; done
  curl -sf http://localhost:7778/health >/dev/null 2>&1 && echo "gateway UP" || echo "gateway DOWN"
  echo "=== tool-calling verification (qwen3_coder parser) ==="
  curl -s -m 90 http://localhost:7778/v1/chat/completions \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"model":"avaniko-ai","messages":[{"role":"user","content":"Create a file named login.html with a hello heading"}],"tools":[{"type":"function","function":{"name":"create_file","description":"create a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"contents":{"type":"string"}},"required":["path","contents"]}}}],"tool_choice":"auto","max_tokens":700}' \
    | python3 -c "import sys,json; d=json.load(sys.stdin); m=d['choices'][0]['message']; tc=m.get('tool_calls'); print('RESULT:', 'TOOL CALL OK ✅ '+json.dumps(tc)[:300] if tc else 'STILL TEXT ❌ '+repr((m.get('content') or '')[:200]))"
  echo ""
  echo "[$(date -u +%FT%TZ)] RESTART COMPLETE"
} >> "$LOG" 2>&1
