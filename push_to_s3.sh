#!/bin/bash
# Push all Avaniko AI source + docs to an S3 bucket.
# Usage:
#   export S3_BUCKET=your-bucket-name          # required
#   export S3_PREFIX=avaniko/$(date -u +%F)    # optional (default: avaniko/YYYY-MM-DD)
#   export AWS_REGION=ap-south-1                # optional
#   # credentials: either `aws configure` once, or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#   bash /workspace/push_to_s3.sh
set -euo pipefail

: "${S3_BUCKET:?Set S3_BUCKET=your-bucket-name first}"
PREFIX="${S3_PREFIX:-avaniko/$(date -u +%F)}"
SRC=/workspace
STAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
TARBALL="/tmp/avaniko_source_${STAMP}.tar.gz"

echo "Bundling source (excluding venvs, models, caches, logs)…"
tar -czf "$TARBALL" -C "$SRC" \
  --exclude='*/venv' --exclude='venv' \
  --exclude='*/__pycache__' --exclude='.cache' \
  --exclude='models' --exclude='mysql' \
  --exclude='logs' --exclude='backups' \
  --exclude='*.tar.gz' --exclude='.git' \
  --exclude='gateway/files' \
  gateway/main.py gateway/start.sh gateway/static \
  gateway/.mysql_env gateway/avaniko_db.sql \
  embed_server.py ocr_server.py start_all.sh backup.sh push_to_s3.sh \
  DOCUMENTATION.md RUNPOD_DEPLOYMENT.md TOKEN_LIMIT_SOLUTION.md \
  API_GUIDE.md AVANIKO_FULL_REPORT.md AVANIKO_PROJECT_REPORT_TAMIL.md \
  2>/dev/null || true

# Fresh MySQL dump so the upload always has current keys/users
mysqldump avaniko > /workspace/gateway/avaniko_db.sql 2>/dev/null || true

SIZE=$(du -h "$TARBALL" | cut -f1)
echo "Bundle: $TARBALL ($SIZE)"

echo "Uploading to s3://$S3_BUCKET/$PREFIX/ …"
aws s3 cp "$TARBALL" "s3://$S3_BUCKET/$PREFIX/$(basename "$TARBALL")"
# also push the individual source tree (browsable) — code + docs only
aws s3 sync "$SRC/gateway/static"  "s3://$S3_BUCKET/$PREFIX/static/" --quiet
aws s3 cp  "$SRC/gateway/main.py"  "s3://$S3_BUCKET/$PREFIX/gateway/main.py"
for f in embed_server.py ocr_server.py start_all.sh backup.sh \
         DOCUMENTATION.md RUNPOD_DEPLOYMENT.md TOKEN_LIMIT_SOLUTION.md \
         API_GUIDE.md AVANIKO_FULL_REPORT.md AVANIKO_PROJECT_REPORT_TAMIL.md; do
  [ -f "$SRC/$f" ] && aws s3 cp "$SRC/$f" "s3://$S3_BUCKET/$PREFIX/$f"
done

echo "Done → s3://$S3_BUCKET/$PREFIX/"
aws s3 ls "s3://$S3_BUCKET/$PREFIX/"
rm -f "$TARBALL"
