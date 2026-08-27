#!/bin/bash
cd /workspace/gateway
exec /workspace/gateway/venv/bin/python -m uvicorn main:app \
  --host 0.0.0.0 --port 7778 \
  --workers 1 --loop asyncio \
  --timeout-keep-alive 300 \
  --log-level info
