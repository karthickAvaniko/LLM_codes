#!/bin/bash
# Full-workspace backup to S3 via incremental sync.
#   - Mirrors the ENTIRE /workspace tree to s3://$S3_BUCKET/$S3_PREFIX/
#   - Uses `aws s3 sync`: only changed/new files upload on re-runs (resumable).
#   - Takes a fresh MySQL dump first so the DB snapshot is consistent.
#
# Usage:
#   bash /workspace/push_workspace_s3.sh            # full mirror (incl. venv + models)
#   LIGHT=1 bash /workspace/push_workspace_s3.sh    # skip venv/models (source+data only, ~150M)
#
# Credentials/config come from /workspace/.s3_env (AWS keys, bucket, region, prefix).
set -euo pipefail

source /workspace/.s3_env
: "${S3_BUCKET:?Set S3_BUCKET in /workspace/.s3_env}"
PREFIX="${S3_PREFIX:-workspace-mirror}"
SRC=/workspace
DEST="s3://$S3_BUCKET/$PREFIX"

# Consistent DB snapshot (restore with: mysql avaniko < gateway/avaniko_db.sql)
echo "[$(date -u +%FT%TZ)] Dumping MySQL…"
mysqldump avaniko > /workspace/gateway/avaniko_db.sql 2>/dev/null || echo "  (mysqldump skipped — DB not reachable)"

# Always-excluded transient junk
EXCLUDES=(
  --exclude '*/__pycache__/*' --exclude '__pycache__/*'
  --exclude '*.pyc' --exclude '*.pyo'
  --exclude '*.tmp' --exclude '*.log'
  --exclude '.ipynb_checkpoints/*'
  --exclude '*.tar.gz'
)

# LIGHT mode drops the rebuildable bulk (28G venv + 23G models + 7.2G gateway/venv)
if [ "${LIGHT:-0}" = "1" ]; then
  echo "[$(date -u +%FT%TZ)] LIGHT mode: excluding venv + models"
  EXCLUDES+=(
    --exclude 'venv/*'
    --exclude 'gateway/venv/*'
    --exclude 'models/*'
    --exclude '.cache/*'
  )
fi

echo "[$(date -u +%FT%TZ)] Syncing $SRC → $DEST …"
aws s3 sync "$SRC" "$DEST" "${EXCLUDES[@]}" --no-progress

echo "[$(date -u +%FT%TZ)] Done. Top-level objects in backup:"
aws s3 ls "$DEST/" || true
