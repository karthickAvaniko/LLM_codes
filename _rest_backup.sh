#!/bin/bash
# Push everything EXCEPT venv (models, .cache, .git, logs, gateway non-venv, misc).
source /workspace/.s3_env
B="s3://$S3_BUCKET/$S3_PREFIX"
echo "[$(date -u +%FT%TZ)] START rest backup (everything except venv)"

# big model weights (45 large shards)
aws s3 sync /workspace/models  "$B/models"  --no-progress
# HF cache (~20G)
aws s3 sync /workspace/.cache  "$B/.cache"  --no-progress
# git history + logs + notebooks
aws s3 sync /workspace/.git    "$B/.git"    --no-progress
aws s3 sync /workspace/logs    "$B/logs"    --no-progress
aws s3 sync /workspace/.ipynb_checkpoints "$B/.ipynb_checkpoints" --no-progress
# gateway leftovers (NOT gateway/venv)
aws s3 sync /workspace/gateway/files "$B/gateway/files" --no-progress
[ -f /workspace/gateway/main.py.monolith.bak ] && aws s3 cp /workspace/gateway/main.py.monolith.bak "$B/gateway/main.py.monolith.bak" --no-progress
# misc loose test assets
for f in test.jpg test.pdf; do
  [ -f "/workspace/$f" ] && aws s3 cp "/workspace/$f" "$B/$f" --no-progress
done

echo "[$(date -u +%FT%TZ)] DONE rest backup"
